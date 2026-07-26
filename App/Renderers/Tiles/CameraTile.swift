import SwiftUI
import HavenCore

/// The two approved camera tile renderings.
///
/// **There is deliberately no 1×1 and no 2×1.** Both were considered and rejected: below two
/// columns a camera feed is a thumbnail of a thumbnail, and a picture too small to recognise a
/// person in is not a camera tile — it is a coloured rectangle claiming to be one. A camera that
/// cannot be given the space gets no tile rather than a misleading one, which is why neither
/// surface routes cameras through `DeviceTileView`'s 4-column grid.
enum CameraTileSize {
    /// 2×2. The still above a caption strip carrying the name, the state, and how old the picture
    /// is.
    case square
    /// 4×2. Full-bleed still with the name over a gradient scrim, and **no** staleness stamp: at
    /// this width the picture *is* the tile, and a stamp floating over it is furniture. The 2×2
    /// needs one because there the still is small enough that "is this now?" is a real question;
    /// here you can see the scene.
    case wide
}

/// A camera on the grid, as a **still** — never a stream.
///
/// Four live feeds on a dashboard is a battery, bandwidth and Home-Assistant-server cost paid
/// continuously for a view that is glanced at for two seconds. So the tile fetches one frame every
/// ten seconds, and stops entirely when the app backgrounds or the tile leaves the screen. Both of
/// those are structural rather than remembered — see `refreshTick`.
struct CameraTile: View {
    let entityId: String
    var size: CameraTileSize = .square
    @Environment(HomeStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    /// Bumped every refresh interval, and fed to `AuthenticatedImage.refreshTick`.
    ///
    /// It starts at **1**, not 0, so the very first load bypasses the image cache. That matters
    /// here and nowhere else: the snapshot URL is stable while its *contents* are the only thing
    /// that changes, so a cached copy is a picture of an arbitrary earlier moment — and the
    /// staleness stamp beneath it would be measured from when that copy was served, not from when
    /// the picture was taken. An honest stamp is only possible over a frame we actually fetched.
    @State private var refreshTick = 1
    /// When the frame currently on screen finished decoding — set by `AuthenticatedImage.onLoad`,
    /// which fires only on success, so a failed refresh leaves the stamp reading the true age of
    /// the last real frame rather than resetting to "just now" over a stale one.
    @State private var capturedAt: Date?

    private var accent: Color { HavenColor.domain(.camera) }

    var body: some View {
        let e = store.state(entityId)
        let s = e.map(CameraState.init)
        let name = TileName.of(entityId, e)
        Group {
            switch size {
            case .square: square(s, name: name)
            case .wide: wide(s, name: name)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.presented = entityId }
        // The whole tile is one element: unlike a media tile it holds no buttons, so combining
        // costs nothing and spares a VoiceOver user two stops for a picture and its caption.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(s.map { AccessibilitySummary.camera(name, $0, capturedAt: capturedAt, now: Date()) } ?? name)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the live view")
        // The trait above makes VoiceOver *say* "button"; it does not wire its activate gesture to
        // a bare `.onTapGesture`. This repo has already shipped that exact regression once — see
        // `SegmentedControl.swift`'s "a real Button, not `.onTapGesture`" comment — and the result
        // is a tile a VoiceOver user can hear described but not open. `MediaPlayerTile` solves it
        // the same way.
        .accessibilityAction { store.presented = entityId }
        // **The refresh loop, and where it stops.**
        //
        // Keyed on `scenePhase`, so backgrounding the app cancels this task and the guard makes the
        // replacement return immediately — the loop cannot run while the app is not on screen.
        // `.task` itself cancels on disappear, which covers the tile scrolling out of the grid.
        // Both are properties of the structure rather than of remembering to tear something down,
        // which is what "stop when the app backgrounds or the tile leaves the screen" has to be:
        // the failure mode is invisible from inside the app and shows up as battery drain and load
        // on the user's own server.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { return }
                refreshTick &+= 1
            }
        }
    }

    // MARK: - 2×2

    private func square(_ s: CameraState?, name: String) -> some View {
        // Two tile rows plus the grid's own row spacing, matching the 4×2 media tile so a camera
        // and a media player line up when both sit under the same room heading.
        let height: CGFloat = 141
        return VStack(spacing: 0) {
            still(s)
                .frame(maxWidth: .infinity)
                .frame(height: height - captionHeight)
                .clipped()
            caption(s, name: name)
                .frame(height: captionHeight)
        }
        .frame(height: height)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(HavenColor.glassStroke, lineWidth: 1))
                .shadow(color: .black.opacity(0.06), radius: 3, y: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var captionHeight: CGFloat { 42 }

    /// Name, then state and age beneath it.
    ///
    /// Two lines rather than one row, because at half of four columns "Front Door Camera" and
    /// "Recording · 12s ago" do not fit side by side on a phone, and the one that would get
    /// ellipsised is the name — leaving a caption strip that says how fresh a picture of *something*
    /// is. Note the state is here in text at all sizes: it is the difference between a camera that
    /// is watching and one that stopped answering, which the picture itself cannot show.
    ///
    /// The stamp re-renders on a five-second cadence rather than every second: the frame behind it
    /// only changes every ten, and a counter ticking once a second on four tiles is both wasted
    /// work and exactly the restless dashboard the design keeps ruling out.
    private func caption(_ s: CameraState?, name: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
            if let s, s.isAvailable, capturedAt != nil {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    Text("\(s.status.label) · \(CameraSnapshotAge.describe(capturedAt: capturedAt, now: context.date))")
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if let s, s.isAvailable {
                // No frame has arrived yet. State only, and deliberately *no* stamp: `describe`
                // reads a nil capture time as "just now", which under a loading placeholder would
                // be a freshness claim about a picture that does not exist — and it would disagree
                // with the accessibility label, which omits the age in exactly this case.
                Text(s.status.label)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                // No stamp at all when there is no live picture: an age would be describing a frame
                // nothing is updating, which is the plausible-blank failure wearing a timestamp.
                Text(s?.status.label ?? "Unavailable")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }

    // MARK: - 4×2

    private func wide(_ s: CameraState?, name: String) -> some View {
        let height: CGFloat = 141
        return still(s)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipped()
            .overlay(alignment: .bottomLeading) { nameScrim(s, name: name) }
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.06), radius: 3, y: 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(HavenColor.glassStroke, lineWidth: 1)
            }
    }

    /// The name over a gradient, which is what makes white text legible over a picture that can be
    /// any colour at all — a floodlit driveway at night and a sunlit garden are both possible under
    /// the same label.
    private func nameScrim(_ s: CameraState?, name: String) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let s, !s.isAvailable {
                Text(s.status.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 22)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.62)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    // MARK: - The still

    /// The snapshot, or a state that is honest about why there isn't one.
    ///
    /// The three non-image phases are drawn differently on purpose. A camera with no picture yet, a
    /// camera whose fetch failed and a camera Home Assistant says is unavailable are three
    /// different situations, and rendering all of them as an empty dark rectangle is precisely the
    /// "looks like a working camera pointed at nothing" failure `ImageLoadOutcome` was built to
    /// stop. Note also what does *not* happen: a refresh of a path that hasn't changed keeps the
    /// current frame on screen (`AuthenticatedImage` only resets to `.loading` when the path
    /// itself changes), so a live tile never flickers back to a placeholder every ten seconds.
    @ViewBuilder
    private func still(_ s: CameraState?) -> some View {
        if let s, s.isAvailable {
            AuthenticatedImage(
                path: CameraState.snapshotPath(for: entityId),
                refreshTick: refreshTick,
                onLoad: { capturedAt = $0 }
            ) { phase in
                switch phase {
                case .image(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .loading:
                    placeholder(symbol: "video.fill", caption: nil)
                case .empty, .failed:
                    placeholder(symbol: "video.slash.fill", caption: "No picture")
                }
            }
            .accessibilityHidden(true)      // the tile's own label already says what this is
        } else {
            placeholder(symbol: "video.slash.fill", caption: s?.status.label ?? "Unavailable")
                .accessibilityHidden(true)
        }
    }

    private func placeholder(symbol: String, caption: String?) -> some View {
        ZStack {
            accent.opacity(0.22)
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 24))
                    .foregroundStyle(accent)
                    .symbolRenderingMode(.hierarchical)
                if let caption {
                    Text(caption).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
