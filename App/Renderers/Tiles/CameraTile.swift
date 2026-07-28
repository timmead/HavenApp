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
    /// 2×2. The still above a caption strip carrying the name, with the age of the picture stamped
    /// over the bottom-right corner of the still itself.
    case square
    /// 4×2. Full-bleed still with the name over a gradient scrim, and **no** staleness stamp: at
    /// this width the picture *is* the tile, and you can see the scene well enough to judge it. The
    /// 2×2 keeps a stamp because there the still is small enough that "is this now?" is a real
    /// question — the difference is how much picture there is to read, which is why the stamp
    /// survived the caption strip that used to carry it.
    case wide
}

/// A camera on the grid, as a **still** — never a stream.
///
/// Four live feeds on a dashboard is a battery, bandwidth and Home-Assistant-server cost paid
/// continuously for a view that is glanced at for two seconds. So the tile fetches one frame every
/// ten seconds, and stops entirely when the app backgrounds or the tile leaves the screen. Both of
/// those are structural rather than remembered — see `refreshPolicy`.
struct CameraTile: View {
    let entityId: String
    var size: CameraTileSize = .square
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation
    @Environment(\.scenePhase) private var scenePhase

    /// Seconds between snapshots. The cycle itself belongs to `AuthenticatedImage`, which starts
    /// each fetch only once the previous one has finished — see `AuthenticatedImage.RefreshPolicy`
    /// for the defect that arrangement exists to make impossible.
    ///
    /// Every load bypasses the image cache, and that matters here and nowhere else: the snapshot
    /// URL is stable while its *contents* are the only thing that changes, so a cached copy is a
    /// picture of an arbitrary earlier moment — and the staleness stamp beneath it would be
    /// measured from when that copy was served, not from when the picture was taken. An honest
    /// stamp is only possible over a frame we actually fetched.
    private let refreshInterval: TimeInterval = 10
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
        .onTapGesture { navigation.presentedEntityId = entityId }
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
        .accessibilityAction { navigation.presentedEntityId = entityId }
    }

    /// **Where the refresh stops.**
    ///
    /// `isActive` is part of `AuthenticatedImage`'s `.task` id, so backgrounding the app cancels
    /// the cycle and the replacement task returns immediately — it cannot run while the app is off
    /// screen. `.task` itself cancels on disappear, which covers the tile scrolling out of the
    /// grid. Both are properties of the structure rather than of remembering to tear something
    /// down, which is what "stop when the app backgrounds or the tile leaves the screen" has to be:
    /// the failure mode is invisible from inside the app and shows up as battery drain and load on
    /// the user's own server.
    private var refreshPolicy: AuthenticatedImageRefresh {
        AuthenticatedImageRefresh(interval: refreshInterval, isActive: scenePhase == .active)
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
                .overlay(alignment: .bottomTrailing) { ageStamp(s) }
            caption(name: name)
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

    private var captionHeight: CGFloat { 26 }

    /// The name, and nothing else.
    ///
    /// It used to carry the state and the age on a second line beneath. Both left, in opposite
    /// directions, and the strip shrank from 42pt to one line — the 16pt goes to the picture, and
    /// the tile's overall 141 is unchanged because it is matched to the 4×2 media tile.
    ///
    /// - The **age** moved onto the still (`ageStamp`), where it is beside the thing it describes
    ///   instead of below it.
    /// - The **state** — "Recording", "Idle", "Streaming" — is gone from this size outright.
    ///   Distinguishing a recording camera from an idle one is not what a glance at a dashboard is
    ///   for, and it was spending a whole line of a two-column tile to do it. What that line was
    ///   really defending is still defended: a camera that *stopped answering* says so inside the
    ///   picture, because `still()` draws `status.label` in its placeholder for an unavailable
    ///   camera and "No picture" for a failed fetch, and both are more legible there — full width,
    ///   with an icon — than they ever were in 9.5pt grey. The state also remains in the
    ///   accessibility label, which never read this strip.
    private func caption(name: String) -> some View {
        Text(name)
            .font(.system(size: 11.5, weight: .semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
    }

    /// How old the picture is, stamped on the picture.
    ///
    /// Drawn on a dark capsule for the same reason `wide()`'s name sits on a gradient: the frame
    /// underneath can be any colour at all — a floodlit driveway at night, a sunlit garden — and
    /// text laid straight onto it is legible over one and invisible over the other. The capsule is
    /// a fixed black rather than a material, so it does not go pale over a bright frame in light
    /// mode.
    ///
    /// **Shown only over a frame that actually arrived** — `isAvailable` and a non-nil
    /// `capturedAt` — which is the same condition the caption used to gate on, for the same
    /// reason: `CameraSnapshotAge.describe` reads a nil capture time as "just now", so a stamp
    /// under a loading placeholder would be a freshness claim about a picture that does not exist,
    /// and it would disagree with the accessibility label, which omits the age in exactly this
    /// case. Over an unavailable or failed camera it would be worse still — an age describing a
    /// frame nothing is updating is the plausible-blank failure wearing a timestamp.
    ///
    /// The stamp re-renders on a five-second cadence rather than every second: the frame behind it
    /// only changes every ten, and a counter ticking once a second on four tiles is both wasted
    /// work and exactly the restless dashboard the design keeps ruling out.
    @ViewBuilder
    private func ageStamp(_ s: CameraState?) -> some View {
        if let s, s.isAvailable, capturedAt != nil {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Text(CameraSnapshotAge.describe(capturedAt: capturedAt, now: context.date))
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(.black.opacity(0.55)))
            }
            .padding(6)
            // The tile's own label already speaks the age (`AccessibilitySummary.camera`), and the
            // tile combines its children — so this would be a second reading of the same fact.
            .accessibilityHidden(true)
        }
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
                refresh: refreshPolicy,
                onLoad: { capturedAt = $0 }
            ) { phase in
                switch phase {
                case .image(let image):
                    // **`Color.clear` with the picture as an overlay, not the picture itself.**
                    //
                    // `aspectRatio(contentMode: .fill)` sizes the image to *cover* what it was
                    // offered, so one of its two dimensions comes back larger than the offer — and a
                    // view that returns an oversized size hands that size to its parent. The tile's
                    // `.frame(maxWidth: .infinity)` does not clamp it and `.clipped()` only trims the
                    // drawing, so the whole tile reported itself wider than its grid column and bled
                    // out past the room's insets, over the tile beside it.
                    //
                    // Overlays are the one composition that cannot do this: the overlay is offered
                    // its host's size and never contributes to it, so `Color.clear` — which accepts
                    // whatever it is offered — fixes the tile at exactly its column, and the picture
                    // overflows *inside* the clip where it is supposed to.
                    //
                    // The overflow was always here: at 16:9 in the old 172×99 still it was about two
                    // points a side and invisible. Making the still 16pt taller (the caption strip
                    // lost a line) turned the fill from width-driven to height-driven and the same
                    // two points became sixteen. The geometry changed; the defect did not.
                    Color.clear
                        .overlay { image.resizable().aspectRatio(contentMode: .fill) }
                        .clipped()
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
