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

    @ViewBuilder var content: (Phase) -> Content

    enum Phase {
        case loading
        case image(Image)
        /// Nothing to show, nothing wrong.
        case empty
        /// Could not be loaded. Distinct from `.empty` on purpose — the caller is expected to draw
        /// these two differently, which is the entire reason this view exists.
        case failed
    }

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
            phase = UIImage(data: data).map { .image(Image(uiImage: $0)) } ?? .failed
        case .empty: phase = .empty
        case .failure: phase = .failed
        }
    }
}
