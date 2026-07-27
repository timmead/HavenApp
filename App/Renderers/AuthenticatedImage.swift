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
/// on. The one piece of real logic that used to live here — the self-paced refresh cycle — is now
/// `AuthenticatedImageRefreshCycle` below, precisely so it can be tested (`SnapshotRefreshCycleTests`).
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

/// How (and whether) an `AuthenticatedImage` keeps re-fetching.
///
/// Declared at file scope for the same reason `AuthenticatedImagePhase` is: a type nested inside a
/// generic view is generic over that view's parameters too, so `AuthenticatedImage<A>.RefreshPolicy`
/// and `AuthenticatedImage<B>.RefreshPolicy` would be different types — and every caller building
/// one outside a call site would have to name a `Content` it has no business knowing.
struct AuthenticatedImageRefresh: Equatable, Hashable {
    /// Target seconds from the *start* of one fetch to the start of the next. The actual wait is
    /// `SnapshotRefresh.delay`, in HavenCore under test, which is what keeps a fetch slower than
    /// this from collapsing the cycle.
    let interval: TimeInterval
    /// `false` suspends the cycle entirely — the app backgrounded, or the surface decided this
    /// image is not worth keeping current. It is part of `.task`'s id, so flipping it stops the
    /// loop structurally rather than through a flag the loop has to remember to check.
    var isActive: Bool = true
}

/// The self-paced snapshot cycle, lifted out of `AuthenticatedImage` so it can be tested.
///
/// It is *only* the loop — no image, no phase, no loader — because the loop is where the defect
/// was. The first version drove refreshes from an external counter that a sibling task bumped on a
/// fixed clock; because the counter was part of `.task`'s id, every tick cancelled whatever fetch
/// was in flight, and wherever a round trip reliably exceeded the interval no fetch ever completed.
/// The property that makes that impossible — **the next fetch is started by the previous one
/// finishing, and nothing else ever interrupts one** — is exactly what a test can hold this to, and
/// could not hold a `View`'s private method to.
///
/// The clock and the wait are injected so a test can run the whole cycle with no wall-clock time
/// and no races. Production passes neither and gets the real ones.
/// `@MainActor` because both the loop and everything it drives already are — `AuthenticatedImage`
/// is a `View`. Isolating it here rather than hopping keeps the injected closures on one actor, so
/// Swift 6 can see there is no sharing to race over.
@MainActor
enum AuthenticatedImageRefreshCycle {
    static func run(
        _ refresh: AuthenticatedImageRefresh,
        now: () -> Date = { Date() },
        sleep: (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        load: () async -> Void
    ) async {
        guard refresh.isActive else { return }
        while !Task.isCancelled {
            let started = now()
            // Awaited to completion. There is no tick that could cancel this, because there is no
            // tick: the only thing that ends the cycle is the enclosing task being cancelled, which
            // is checked *after* the load rather than being able to abandon one mid-flight.
            await load()
            if Task.isCancelled { return }
            // How long to wait is HavenCore's decision (`SnapshotRefresh.delay`, under test) — a
            // fetch slower than the interval degrades to a lower frame rate instead of collapsing
            // the cycle.
            let delay = SnapshotRefresh.delay(interval: refresh.interval,
                                              duration: now().timeIntervalSince(started))
            await sleep(delay)
        }
    }
}

struct AuthenticatedImage<Content: View>: View {
    /// The `entity_picture`-style reference to load: relative to the current base URL, or already
    /// absolute (third-party artwork). `nil` or blank means the entity has no picture, and gives
    /// `.empty` — never `.failed`.
    let path: String?

    /// Keeps the image fresh, for the camera surfaces. `nil` — the default, and what artwork wants
    /// — is a single cached load.
    ///
    /// **The cycle is owned by this view's own `.task`, and each fetch is started by the previous
    /// one finishing.** That is the fix for a real defect, not a refactor. The first version drove
    /// refreshes from an external counter that a *sibling* task bumped on a fixed clock; because
    /// the counter was part of `.task`'s id, every tick cancelled whatever fetch was in flight.
    /// Wherever a round trip reliably exceeded the interval — a Nabu Casa relay, a 4K still, a slow
    /// `camera_proxy` — no fetch ever completed, `.cancelled` maps to "change nothing" so `phase`
    /// stayed `.loading` forever, and the user got a permanent placeholder while the app spent one
    /// cancelled full-resolution JPEG request per second achieving it. Nothing failed, so there was
    /// nothing to show and nothing to log.
    ///
    /// With the loop and the load in the same task there is no tick to cancel anything: a slow link
    /// degrades to a lower frame rate, which is what `SnapshotRefresh` computes and tests.
    var refresh: AuthenticatedImageRefresh? = nil

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
            .task(id: Request(path: path, refresh: refresh)) { await run() }
    }

    /// `.task`'s id: a path change or a change to the refresh policy each restart the cycle.
    private struct Request: Equatable, Hashable {
        let path: String?
        let refresh: AuthenticatedImageRefresh?
    }

    /// One load, or a self-paced cycle of them.
    ///
    /// The cycle stops when the task is cancelled, which `.task` does on disappear — the same
    /// structural guarantee the single-load case has always had, now covering the repeating one
    /// too.
    private func run() async {
        guard let refresh else {
            await load(policy: .useCache)
            return
        }
        await AuthenticatedImageRefreshCycle.run(refresh) { await load(policy: .reload) }
    }

    private func load(policy: AuthenticatedImageLoader.CachePolicy) async {
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
        let outcome = await loader.image(at: path, policy: policy)
        // `nil` is cancellation: leave whatever is on screen exactly as it is.
        guard let state = outcome.displayState else { return }
        switch state {
        case .image(let data):
            // A `Data` that isn't a decodable image is a failure, not a blank — the loader can only
            // vouch for the bytes arriving, not for what they are.
            guard let decoded = await Self.decode(data) else { fail(); return }
            phase = .image(Image(uiImage: decoded))
            onLoad?(Date())
        case .empty: phase = .empty
        case .failure: fail()
        }
    }

    /// A failure, applied only where there is nothing better on screen already.
    ///
    /// **A failed *refresh* keeps the frame it has.** One 500 from Home Assistant used to blank a
    /// working camera tile to a "No picture" placeholder — while the caption strip beside it went
    /// on stamping an age for the frame that had just been removed, because `onLoad` (correctly)
    /// hadn't fired. That is two things on screen contradicting each other, and it contradicted
    /// `onLoad`'s own documented promise that the tile "keeps saying 3m ago over the last real
    /// frame".
    ///
    /// The last good frame plus an age that keeps climbing is both honest and more useful than a
    /// placeholder: the picture is real, it is exactly as old as the stamp says, and a camera that
    /// has genuinely stopped answering announces itself as the stamp grows. A first load with
    /// nothing behind it still fails visibly, which is the case the error state exists for.
    private func fail() {
        if case .image = phase { return }
        phase = .failed
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
