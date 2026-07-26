import SwiftUI
import HavenCore

/// Displays an image that lives behind Home Assistant's authentication — media-player artwork
/// (`entity_picture`) or a camera snapshot (`/api/camera_proxy/<entity_id>`).
///
/// **Use this instead of `AsyncImage` for anything served by Home Assistant.** `AsyncImage` cannot
/// attach an `Authorization` header, so pointed at these paths it 401s and renders its placeholder
/// — a blank tile indistinguishable from a working camera with nothing in front of it.
///
/// Everything that could be got wrong is decided in HavenCore, under test: which URL a path
/// resolves to, whether the token may be attached, what is cached, and how an outcome maps to
/// something to draw. What lives here is glue only — a `.task` and a phase for the body to switch
/// on — because `App/` has no test target.
///
/// The load is started by `.task(id:)`, which is doing real work and not merely idiomatic: it
/// cancels when the view disappears and again whenever the id changes, so a fast scroll through a
/// dashboard abandons the tiles it passed instead of piling their requests up behind the ones now
/// on screen.
/// What `AuthenticatedImage` currently has to show.
///
/// Declared outside the view rather than nested inside it because the view is generic over its
/// content: a nested `Phase` would be spelled `AuthenticatedImage<Content>.Phase`, so the closure
/// parameter's type would depend on the very generic parameter the closure's *return* type is
/// meant to infer, and every call site fails with "generic parameter 'Content' could not be
/// inferred". `AuthenticatedImage.Phase` still spells it, via the typealias below.
enum AuthenticatedImagePhase {
    case loading
    case image(Image)
    /// Nothing to show, nothing wrong.
    case empty
    /// Could not be loaded. Distinct from `.empty` on purpose — the caller is expected to draw
    /// these two differently, which is the entire reason this view exists.
    case failed
}

struct AuthenticatedImage<Content: View>: View {
    /// The `entity_picture`-style reference to load: relative to the current base URL, or already
    /// absolute (third-party artwork). `nil` or blank means the entity has no picture, and gives
    /// `.empty` — never `.failed`.
    let path: String?

    /// Bump to fetch a fresh copy, for the camera tiles' periodic snapshot refresh: the snapshot
    /// URL is stable and its *contents* are the thing that changes, so a cached copy would freeze
    /// the view on the first frame ever fetched. Any non-zero value bypasses the cache; the
    /// default (`0`) is an ordinary cached load, which is what artwork wants.
    var refreshTick: Int = 0

    /// Called with the moment a frame finished decoding, and **only** on success.
    ///
    /// The camera tiles' staleness stamp is derived from this rather than from when the refresh was
    /// *requested*, and the difference is the whole point: a refresh that 401s or times out must
    /// leave the clock where it was, so the tile keeps saying "3m ago" over the last real frame
    /// instead of resetting to "just now" over a picture nothing has updated. Resetting it on a
    /// failed request would be the confident-blank failure this view exists to prevent, wearing a
    /// timestamp.
    var onLoad: ((Date) -> Void)? = nil

    @ViewBuilder var content: (Phase) -> Content

    typealias Phase = AuthenticatedImagePhase

    @Environment(AppModel.self) private var app
    @State private var phase: Phase = .loading
    /// What `phase` currently reflects, so a *different* image doesn't inherit the previous one's
    /// picture while it loads (tiles are recycled), while a refresh of the *same* one keeps showing
    /// the current frame instead of flashing a placeholder every tick.
    @State private var displayedPath: String?

    var body: some View {
        content(phase)
            .task(id: Request(path: path, tick: refreshTick)) { await load() }
    }

    /// `.task`'s id: both fields, so a path change and a refresh tick each restart the load.
    private struct Request: Equatable, Hashable {
        let path: String?
        let tick: Int
    }

    private func load() async {
        if displayedPath != path {
            phase = .loading
            displayedPath = path
        }
        guard let loader = app.imageLoader else {
            // No session — nothing on screen should be asking for an image. Reported as a failure
            // rather than as `.empty` because it is one; a blank here is the very thing this view
            // exists to stop.
            phase = path == nil ? .empty : .failed
            return
        }
        let outcome = await loader.image(at: path, policy: refreshTick == 0 ? .useCache : .reload)
        // `nil` is cancellation: leave whatever is on screen exactly as it is.
        guard let state = outcome.displayState else { return }
        switch state {
        case .image(let data):
            // A `Data` that isn't a decodable image is a failure, not a blank — the loader can only
            // vouch for the bytes arriving, not for what they are.
            guard let decoded = await Self.decode(data) else { phase = .failed; return }
            phase = .image(Image(uiImage: decoded))
            onLoad?(Date())
        case .empty: phase = .empty
        case .failure: phase = .failed
        }
    }

    /// Decodes off the main actor.
    ///
    /// This used to be a plain `UIImage(data:)` on the MainActor, which was fine while the only
    /// caller was a single piece of album artwork loaded once. The camera tiles changed that: four
    /// of them on a dashboard, each re-fetching a full-resolution JPEG every ten seconds on
    /// independent, unsynchronised cadences. Tens of milliseconds of decode landing on the main
    /// thread at arbitrary moments is the definition of a scroll hitch, so it moves off.
    ///
    /// **`preparingForDisplay()` is what makes the move real.** `UIImage(data:)` is lazy — it
    /// parses the header and defers the actual decode until something draws it, which on the main
    /// thread is exactly where the cost was in the first place. Without this call, "decoding off
    /// the main actor" would be a change that measured as no change at all. It returns `nil` for an
    /// image it cannot prepare, and the original is used in that case rather than failing a frame
    /// that decoded perfectly well.
    ///
    /// `UIImage` crosses back rather than `Image`: it is `Sendable` and the SwiftUI wrapper is
    /// built on the main side, so nothing here depends on `Image`'s own sendability.
    private static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { return nil }
            return image.preparingForDisplay() ?? image
        }.value
    }
}
