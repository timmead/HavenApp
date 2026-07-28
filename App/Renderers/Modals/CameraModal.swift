import SwiftUI
import UIKit
import AVFoundation
import HavenCore

/// The camera's live view.
///
/// Everything that could be got wrong is decided in HavenCore under test — whether to ask for a
/// stream at all, how the returned playlist resolves against the address the app is *currently*
/// using, what the fallback is, and which binary sensors belong to this camera. What lives here is
/// the player, the controls, and the teardown.
struct CameraModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    /// What we resolved to play, or `nil` while still asking. The three states are drawn
    /// differently: a spinner, a video, and an error — never a black rectangle, which is what an
    /// unresolved source handed to `AVPlayer` looks like and is indistinguishable from a camera
    /// pointed at a dark room.
    @State private var source: CameraStreamSource?
    @State private var player: AVPlayer?
    /// **Muted by default, every time.** A camera that starts talking the moment it is opened is
    /// startling in a quiet house, and audio is the part of a feed most likely to be overheard by
    /// someone who did not open the app. Deliberately not persisted: "for that viewing" means
    /// exactly that, and a remembered preference would make the *next* opening the startling one.
    @State private var isMuted = true
    /// Whether this view currently holds the shared audio route. Tracked rather than inferred from
    /// `isMuted`, so releasing it is tied to having taken it — see `releaseAudioSession`.
    @State private var holdsAudioSession = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let e = store.state(entityId)
        let s = e.map(CameraState.init)
        let name = TileName.of(entityId, e)
        let accent = HavenColor.domain(.camera)
        // No `ScrollView` here — that belongs to `DeviceModalView`, which needs this body's *ideal*
        // height to size the sheet's detent. See `MediaPlayerModal` for the same note.
        VStack(spacing: 12) {
            header(s, name: name, accent: accent, unavailable: e?.isUnavailable ?? false)
            feed(s, accent: accent)
            events(accent: accent)
        }
        // Everything about the stream's life hangs off this one key, so there is exactly one place
        // that starts a player and one that stops it.
        //
        // - **Availability.** A camera that was unavailable when the modal opened (an NVR reboot, a
        //   Wi-Fi blip) used to stay showing "Unavailable" until the user closed and reopened the
        //   sheet, while the header subtitle a few points above it had already updated to "Idle"
        //   off the same state push — two parts of one modal disagreeing on screen.
        // - **Foreground.** The tiles got a structural guarantee that they stop on background; the
        //   component actually holding a live stream needs it more, and `.task` cancels on
        //   *disappear*, which backgrounding is not. Coming back rebuilds rather than resumes:
        //   `play()` starts at the live edge when a player is *created*, not after a pause, so
        //   resuming would leave a live indicator pulsing over a frame minutes old — the same class
        //   of dishonesty as a stale staleness stamp. Home Assistant's stream token may well have
        //   expired by then too.
        .task(id: TaskKey(entityId: entityId,
                          isAvailable: s?.isAvailable ?? false,
                          isForeground: scenePhase == .active)) {
            guard scenePhase == .active else { teardown(); return }
            await start(s)
        }
        // **Teardown, and why it is here rather than only in `.task`'s cancellation.** Cancelling
        // the task stops us *asking* for things; it does nothing to an `AVPlayer` that is already
        // running, which would go on pulling segments from the user's Home Assistant — and go on
        // holding an open video connection to a camera in their home — for as long as the object
        // lived. A lingering stream is a battery drain and a privacy problem in the same breath.
        .onDisappear { teardown() }
    }

    /// `.task`'s id. A struct rather than a tuple so the intent of each field survives.
    private struct TaskKey: Equatable {
        let entityId: String
        let isAvailable: Bool
        let isForeground: Bool
    }

    // MARK: - Header

    /// Icon · name · state · **Protect hand-off** · close.
    ///
    /// The hand-off occupies the slot the other modals give a power toggle, and there is
    /// deliberately no toggle here: `camera.turn_off` exists, but a control that silently stops a
    /// security camera recording does not belong one tap inside a thumbnail. Where no vendor app
    /// answers, the slot is simply empty — a ladder, never a cliff.
    @ViewBuilder
    private func header(_ s: CameraState?, name: String, accent: Color, unavailable: Bool) -> some View {
        let subtitle = [s?.status.label, s?.brand].compactMap { $0 }.joined(separator: " · ")
        if let url = handoffURL {
            ModalHeader(systemImage: "video.fill", title: name, subtitle: subtitle, accent: accent,
                        unavailable: unavailable,
                        accessory: AnyView(handoffButton(url, accent: accent)))
        } else {
            ModalHeader(systemImage: "video.fill", title: name, subtitle: subtitle, accent: accent,
                        unavailable: unavailable)
        }
    }

    /// The first candidate iOS says it can actually open, or `nil` — in which case no button is
    /// drawn. Identical in shape to `MediaPlayerModal`'s Sonos hand-off, and identical for the same
    /// reason: a control that looks live and does nothing is worse than its absence. (`canOpenURL`
    /// answers false for any scheme missing from `LSApplicationQueriesSchemes`; `unifi-protect` is
    /// declared in `Info.plist`.)
    private var handoffURL: URL? {
        let info = store.home.registryInfo[entityId]
        return VendorHandoff.candidates(platform: info?.platform, uniqueId: info?.uniqueId)
            .first { UIApplication.shared.canOpenURL($0) }
    }

    private func handoffButton(_ url: URL, accent: Color) -> some View {
        Button { openURL(url) } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.forward.app.fill").font(.system(size: 12, weight: .bold))
                Text("Protect").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(accent.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open in UniFi Protect")
    }

    // MARK: - The feed

    @ViewBuilder
    private func feed(_ s: CameraState?, accent: Color) -> some View {
        ZStack {
            switch source {
            case .hls:
                if let player {
                    PlayerLayerView(player: player)
                } else {
                    feedPlaceholder(symbol: "video.fill", caption: nil, accent: accent)
                }
            case .snapshotRefresh:
                snapshotFallback(accent: accent)
            case .unavailable:
                feedPlaceholder(symbol: "video.slash.fill",
                                caption: s?.status.label ?? "Unavailable", accent: accent)
            case nil:
                feedPlaceholder(symbol: "video.fill", caption: "Connecting…", accent: accent)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topLeading) { if isLive { liveDot.padding(12) } }
        // Bottom-right, on the feed itself rather than in a control row below it: the thing the
        // control governs is what the feed is *emitting*, and putting it anywhere else makes
        // "is this camera listening to my house right now?" a question you have to hunt for.
        .overlay(alignment: .bottomTrailing) { if case .hls = source { muteButton.padding(12) } }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(HavenColor.glassStroke, lineWidth: 1)
        }
    }

    private var isLive: Bool {
        if case .hls = source { return true }
        return false
    }

    /// **A pulsing dot and nothing else.** No "LIVE" caption and no clock — both were explicitly
    /// removed: the dot is the whole indicator, and the two of them together were three things
    /// saying one thing.
    ///
    /// Under Reduce Motion it stops pulsing and simply stays lit. That keeps the information (the
    /// feed is live) and drops the animation, which is exactly the trade the setting asks for.
    ///
    /// The label is the accessibility counterpart the visible design deliberately doesn't have: a
    /// red dot conveys "live" to everyone who can see it and to nobody else, so the word exists in
    /// the accessibility tree even though it appears nowhere on screen.
    private var liveDot: some View {
        PulsingDot()
            .accessibilityLabel("Live")
    }

    /// Muted on open, unmuted only by a deliberate tap. The state is in the `accessibilityValue`
    /// rather than folded into the label, so VoiceOver announces the change when it flips instead
    /// of renaming the button.
    private var muteButton: some View {
        Button {
            setMuted(!isMuted)
        } label: {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.black.opacity(0.45)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Camera sound")
        .accessibilityValue(isMuted ? "Muted" : "On")
    }

    /// The no-stream fallback: the same still the tiles show, refreshed about once a second while
    /// the modal is open. Not a video, and it does not pretend to be one — there is no live dot
    /// over it and no speaker control beside it, because there is no live audio to control.
    private func snapshotFallback(accent: Color) -> some View {
        // Self-paced: the next fetch starts when the last one finishes, so a link on which a
        // snapshot takes longer than a second degrades to a lower frame rate instead of to a
        // permanently empty rectangle. This is the branch that gets taken whenever `camera/stream`
        // yields nothing — including for every camera whose response shape this branch documents as
        // unverified — so it is the one that must not be the broken one.
        AuthenticatedImage(
            path: CameraState.snapshotPath(for: entityId),
            refresh: AuthenticatedImageRefresh(interval: CameraStream.snapshotRefreshInterval,
                                               isActive: scenePhase == .active)
        ) { phase in
            switch phase {
            case .image(let image): image.resizable().aspectRatio(contentMode: .fit)
            case .loading: feedPlaceholder(symbol: "video.fill", caption: "Connecting…", accent: accent)
            case .empty, .failed: feedPlaceholder(symbol: "video.slash.fill", caption: "No picture", accent: accent)
            }
        }
        .accessibilityLabel("Live view, still images")
    }

    private func feedPlaceholder(symbol: String, caption: String?, accent: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(accent)
                .symbolRenderingMode(.hierarchical)
            if let caption {
                Text(caption).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Events

    /// **Events**, not "Related": the card answers "what has this camera seen?", and every chip on
    /// it is something that happened in front of the lens. Which sensors qualify is `CameraEvents`'
    /// decision, under test — a card headed "Events" listing the next room's motion sensor would be
    /// a false statement about the user's home, so the join is not made here.
    @ViewBuilder
    private func events(accent: Color) -> some View {
        let sensors = store.cameraEvents(entityId)
        if !sensors.isEmpty {
            FacetCard(title: "Events") {
                // Wraps rather than scrolls: a doorbell chip that has to be swiped into view is a
                // doorbell chip nobody sees.
                FlowRow(spacing: 7) {
                    ForEach(sensors) { sensor in
                        eventChip(sensor, accent: accent)
                    }
                }
            }
        }
    }

    private func eventChip(_ sensor: CameraEventSensor, accent: Color) -> some View {
        let state = store.state(sensor.entityId).map(BinarySensorState.init)
        let isActive = state?.isActive ?? false
        // State as a word, not only as a tint — the amber is unreadable to a VoiceOver user and
        // ambiguous to anyone else, and "Motion" alone doesn't say whether there *is* any.
        return HavenChip(systemImage: sensor.kind.symbol,
                         text: "\(sensor.kind.label) · \(isActive ? "Active" : "Clear")",
                         accent: isActive ? HavenColor.warning : accent.opacity(0.7))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(sensor.kind.label), \(isActive ? "active" : "clear")")
    }

    // MARK: - Lifecycle

    /// Resolves what to play, once, when the modal opens.
    ///
    /// The base URL is read here — at the moment the player is built — rather than captured
    /// earlier, because the app fails over between its local and remote addresses mid-session and a
    /// playlist resolved against the wrong host plays as a black rectangle with no error anywhere.
    /// **A cancellation check follows every `await`, before anything observable is touched.** This
    /// is the invariant `AppModel.connect()` already holds, and it is load-bearing here for a
    /// specific reason: `HAWebSocketClient.request` is a bare continuation with no cancellation
    /// handling, so cancelling this task does *not* cancel the in-flight `camera/stream` command —
    /// Home Assistant answers whenever its stream worker is ready, which for a Protect camera can
    /// be a second or more, and this function then resumes.
    ///
    /// Without the guards, a user who opened a camera and swiped the sheet away before it resolved
    /// got an `AVPlayer` **created and started after `onDisappear` had already run**. `teardown()`
    /// fires exactly once, on disappear; a player built after it has no owner and no path to being
    /// stopped, and it starts pulling HLS segments from a camera inside the user's home
    /// immediately. That is a direct hole in "tear the stream down on dismiss", in the one place
    /// the plan calls out as both a battery drain and a privacy problem.
    ///
    /// **Nothing on screen is disturbed until there is something to replace it with.** The teardown
    /// happens after the awaits, immediately before the new player is built — not on entry. Tearing
    /// down first meant that a camera merely *flapping* between `idle` and `unavailable` (the exact
    /// NVR-reboot case the availability re-key exists for) blanked a working feed to "Connecting…"
    /// for however long `camera/stream` took to answer, once per transition.
    private func start(_ s: CameraState?) async {
        let plan = await CameraPlaybackPlan.resolve(
            state: s,
            isCancelled: { Task.isCancelled },
            streamPath: { await store.cameraStreamPath(entityId) },
            baseURL: { await app.currentBaseURL() }
        )
        // **The whole point of the plan being a value.** `.cancelled` is the one outcome that
        // touches nothing at all — no player is constructed, `source` is left as it was, and
        // `replace` is never called. Every construction of an `AVPlayer` in this file is inside the
        // `.show` branch below, which is what makes "a player is never created after teardown" a
        // property a test can hold this to rather than a promise spread across four `guard`s.
        guard case .show(let resolved) = plan else { return }
        guard case .hls(let url) = resolved else {
            replace(with: resolved, player: nil)
            return
        }
        // **Before `play()`, and it matters even though we start muted.** Starting an HLS asset
        // with an audio track activates the shared `AVAudioSession`, and the app's default
        // category (`.soloAmbient`) does not mix — so opening a camera would interrupt whatever
        // the user was listening to. `isMuted` silences *our* output; it does not stop that
        // activation. `.ambient` mixes and is silenced by the ring switch, which is the right
        // default for a feed nobody has asked to hear. Unmuting escalates to `.playback`, which is
        // what makes the sound actually audible on a phone set to silent.
        //
        // Guarded on `isMuted`, because this now also runs for a *replacement* — a flap, a return
        // from the background — and a user who had already turned the sound on would otherwise have
        // their `.playback` route quietly downgraded back to `.ambient` underneath them, taking the
        // ring switch back with it. The control would still read "on" while the phone stayed quiet.
        if isMuted { try? AVAudioSession.sharedInstance().setCategory(.ambient) }
        let player = AVPlayer(url: url)
        player.isMuted = isMuted
        // No `automaticallyWaitsToMinimizeStalling` fiddling and no seek-to-live: HA's HLS playlist
        // is a live window, so a *newly created* player starts at the live edge on its own. That is
        // also why returning from the background rebuilds instead of resuming — see the task key.
        player.play()
        replace(with: resolved, player: player)
    }

    /// Swaps in a new source and player, stopping whatever was there first.
    ///
    /// One function so "the old player is always stopped before the new one is shown" is a property
    /// of the code rather than of every caller remembering the pair — and so the swap is a single
    /// synchronous step with no await in the middle for a placeholder to appear through.
    private func replace(with source: CameraStreamSource, player: AVPlayer?) {
        stopPlayer()
        self.player = player
        self.source = source
    }

    /// Stops the stream, lets go of it, and gives back the audio route. The *leaving* path — the
    /// sheet being dismissed, or the app going to the background. A replacement goes through
    /// `replace(with:player:)` instead, which stops the old player without touching audio.
    private func teardown() {
        stopPlayer()
        source = nil
        // The audio route is released here and not in `stopPlayer`, so a stream *replacement*
        // (a flap, a return from the background) doesn't silently revoke a sound the user
        // deliberately turned on. Only leaving the view does.
        releaseAudioSession()
    }

    private func stopPlayer() {
        player?.pause()
        // Detaching the item is what actually ends the network activity — a paused `AVPlayer` still
        // holds its asset, and an HLS asset holds a connection to the user's Home Assistant.
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    /// Applies the user's mute choice to the current player and to the audio route.
    ///
    /// `.playback` is what makes an unmute audible at all on a phone with the ring switch set to
    /// silent, which is the phone most people are holding — without it, "tap to enable sound" would
    /// do nothing for them and look like a broken control. It is taken only on an explicit unmute,
    /// so opening a camera never interrupts what the user was listening to; only deliberately
    /// turning its sound on does.
    private func setMuted(_ muted: Bool) {
        isMuted = muted
        player?.isMuted = muted
        guard !muted else { releaseAudioSession(); return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        holdsAudioSession = true
    }

    /// Hands the audio route back, and **only if we ever took it**. Deactivating a session this
    /// view never activated would send `.notifyOthersOnDeactivation` to whatever else is playing,
    /// on behalf of a camera the user opened and closed without ever asking for sound.
    private func releaseAudioSession() {
        guard holdsAudioSession else { return }
        holdsAudioSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

// MARK: - What to play

/// The outcome of `CameraModal.start`'s resolution, as a value.
///
/// Lifted out of the view so the cancellation rule can be tested, because it is a *security and
/// battery* rule rather than a cosmetic one. `HAWebSocketClient.request` is a bare continuation
/// with no cancellation handling, so cancelling the modal's task does not cancel the in-flight
/// `camera/stream` command — Home Assistant answers whenever its stream worker is ready (a second
/// or more for a Protect camera) and the function then resumes. Without a check after every
/// `await`, a user who opened a camera and swiped the sheet away before it resolved got an
/// `AVPlayer` **created and started after `onDisappear` had already run**: no owner, no path to
/// being stopped, and pulling HLS segments from a camera inside their home from that moment on.
///
/// `.cancelled` therefore means *change nothing* — not "show unavailable", which would blank a feed
/// on the way out, and emphatically not "carry on and build the player".
enum CameraPlaybackPlan: Equatable {
    /// The task was cancelled part-way through resolving. Touch nothing.
    case cancelled
    /// What to put on screen. `.hls` is the only case that gets a player.
    case show(CameraStreamSource)

    /// Resolves what to play. Every input that reaches outside this function is a parameter, so a
    /// test can make cancellation land in each of the two windows that matter — after
    /// `camera/stream` answers, and after the base URL is read.
    ///
    /// The base URL is read *here*, at the moment the player is about to be built, rather than
    /// captured when the modal opened: the app fails over between its local and remote addresses
    /// mid-session, and a playlist resolved against the wrong host plays as a black rectangle with
    /// no error anywhere.
    @MainActor
    static func resolve(
        state: CameraState?,
        isCancelled: () -> Bool,
        streamPath: () async -> String?,
        baseURL: () async -> URL?
    ) async -> CameraPlaybackPlan {
        guard let state else { return .show(.unavailable) }
        // `nil` is every way this can fail to produce a URL — never asked, command errored, socket
        // dropped — and `CameraStream.source` turns all of them into the still fallback rather than
        // into an error, because the still is a working live view, just a slower one.
        let path = CameraStream.shouldRequestStream(state) ? await streamPath() : nil
        if isCancelled() { return .cancelled }
        guard let baseURL = await baseURL() else { return .show(.unavailable) }
        if isCancelled() { return .cancelled }
        return .show(CameraStream.source(hlsPath: path, state: state, baseURL: baseURL))
    }
}

// MARK: - Pieces

/// The live indicator: one dot, pulsing, and nothing else.
///
/// Its own view so the `@State` driving the animation belongs to the dot rather than to the modal
/// — a modal-level flag would restart the pulse on every state push from Home Assistant, which for
/// a camera arrives whenever motion is detected.
private struct PulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(HavenColor.liveIndicator)
            .frame(width: 10, height: 10)
            .shadow(color: .black.opacity(0.4), radius: 2)
            .opacity(dimmed ? 0.35 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                       value: dimmed)
            .onAppear { if !reduceMotion { dimmed = true } }
    }
}

// `PlayerLayerView` (which draws the feed) and `FlowRow` (which wraps the event chips) used to live
// here. Neither is camera-specific — one wraps an `AVPlayerLayer`, the other is a `Layout` over
// arbitrary subviews — so both now sit in `App/DesignSystem/`, where the next caller can find them
// without importing from a camera modal.
