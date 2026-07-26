import SwiftUI
import UIKit
import HavenCore

struct MediaPlayerModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// Non-nil only while dragging the volume slider.
    @State private var dragVolume: Double?

    var body: some View {
        let e = store.state(entityId)
        let s = e.map(MediaPlayerState.init)
        let name = TileName.of(entityId, e)
        let accent = HavenColor.domain(.mediaPlayer)
        VStack(spacing: 12) {
            header(s, name: name, deviceClass: e?.deviceClass, accent: accent)
            ScrollView {
                VStack(spacing: 12) {
                    nowPlaying(s, name: name, deviceClass: e?.deviceClass, accent: accent)
                    transport(s, accent: accent)
                    volume(s, accent: accent)
                    source(s, accent: accent)
                }
            }
            // No trailing `Spacer` after the `ScrollView` — unlike the other modals, whose bodies
            // are plain stacks. Two flexible siblings in one `VStack` split the height between
            // them, which at the `.medium` detent squashes the scroll view to roughly its content's
            // ideal size and parks the rest as blank space below. The scroll view is the flexible
            // element here; it fills what the header leaves.
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: - Header

    /// Icon · name · state · **power** · close.
    ///
    /// The toggle is power and only power. Where the device doesn't declare both `turn_on` and
    /// `turn_off` there is simply no toggle — repurposing it for play/pause would make the same
    /// control mean different things on different devices, which is the inconsistency the switch
    /// renderer was corrected for.
    ///
    /// A Sonos speaker is the one exception, and it is a *substitution*, not a second meaning: it
    /// has no meaningful power state at all, so the slot carries a hand-off to Sonos's own app —
    /// which is where the grouping and browsing Haven deliberately doesn't implement actually live.
    /// The platform check is here rather than in `VendorHandoff` because it is a question about
    /// what this header shows; `VendorHandoff` only ever produces candidate URLs.
    @ViewBuilder
    private func header(_ s: MediaPlayerState?, name: String, deviceClass: String?, accent: Color) -> some View {
        let subtitle = [s?.playback.label, s?.source].compactMap { $0 }.joined(separator: " · ")
        let icon = IconMap.symbol(domain: .mediaPlayer, deviceClass: deviceClass)
        if isSonos, let url = handoffURL {
            ModalHeader(systemImage: icon, title: name, subtitle: subtitle, accent: accent,
                        accessory: AnyView(handoffButton(url, accent: accent))) { dismiss() }
        } else if s?.features.supportsPower ?? false {
            ModalHeader(systemImage: icon, title: name, subtitle: subtitle, accent: accent,
                        toggle: Binding(get: { s?.isActive ?? false },
                                        set: { store.setMediaPower(entityId, on: $0) })) { dismiss() }
        } else {
            ModalHeader(systemImage: icon, title: name, subtitle: subtitle, accent: accent) { dismiss() }
        }
    }

    private var isSonos: Bool { store.home.registryInfo[entityId]?.platform == "sonos" }

    /// The first candidate iOS says it can actually open, or `nil` — in which case the button is
    /// not drawn at all. A ladder, never a cliff: the alternative is a control that looks live and
    /// does nothing, which is worse than its absence. (`canOpenURL` answers false for any scheme
    /// missing from `LSApplicationQueriesSchemes`; both are declared in `Info.plist`.)
    private var handoffURL: URL? {
        let info = store.home.registryInfo[entityId]
        return VendorHandoff.candidates(platform: info?.platform, uniqueId: info?.uniqueId)
            .first { UIApplication.shared.canOpenURL($0) }
    }

    private func handoffButton(_ url: URL, accent: Color) -> some View {
        Button { openURL(url) } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.forward.app.fill").font(.system(size: 12, weight: .bold))
                Text("Sonos").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(accent.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open in Sonos")
    }

    // MARK: - Now playing

    @ViewBuilder
    private func nowPlaying(_ s: MediaPlayerState?, name: String, deviceClass: String?, accent: Color) -> some View {
        FacetCard {
            HStack(alignment: .top, spacing: 12) {
                AuthenticatedImage(path: s?.artworkPath) { phase in
                    switch phase {
                    case .image(let image): image.resizable().aspectRatio(contentMode: .fill)
                    case .loading, .empty, .failed:
                        ZStack {
                            accent.opacity(0.22)
                            Image(systemName: IconMap.symbol(domain: .mediaPlayer, deviceClass: deviceClass))
                                .font(.system(size: 24)).foregroundStyle(accent).symbolRenderingMode(.hierarchical)
                        }
                    }
                }
                .frame(width: 74, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(s?.title ?? name)
                        .font(.system(size: 15, weight: .bold)).lineLimit(2)
                    // An idle player says so; one that reported a title but no artist gets no
                    // second line at all, rather than an empty one holding space open.
                    if let secondary = s?.secondaryLine {
                        Text(secondary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    } else if !(s?.hasMedia ?? false) {
                        Text("Nothing playing").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(s.map { AccessibilitySummary.mediaPlayer(name, $0) } ?? name)
            }
            if let s, s.position != nil {
                progress(s, accent: accent)
            }
        }
    }

    /// The progress bar, ticking locally.
    ///
    /// Home Assistant reports the position once and then says nothing until it changes, so this is
    /// interpolated from `media_position_updated_at` (`MediaProgress`, in HavenCore with tests).
    /// The `TimelineView` exists **only** on the playing branch: that is what stops the ticking
    /// when paused, structurally rather than by remembering to — a paused player takes the static
    /// branch, where the date passed in cannot affect the result because `MediaProgress.elapsed`
    /// ignores `now` unless the player is playing.
    @ViewBuilder
    private func progress(_ s: MediaPlayerState, accent: Color) -> some View {
        if s.isPlaying {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                progressBar(s, now: context.date, accent: accent)
            }
        } else {
            progressBar(s, now: Date(), accent: accent)
        }
    }

    private func progressBar(_ s: MediaPlayerState, now: Date, accent: Color) -> some View {
        let elapsed = MediaProgress.elapsed(position: s.position, updatedAt: s.positionUpdatedAt,
                                            isPlaying: s.isPlaying, duration: s.duration, now: now)
        let fraction = MediaProgress.fraction(elapsed: elapsed, duration: s.duration)
        return VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(HavenColor.levelTrack)
                    // No fraction (a live stream with no duration) means no fill — an empty track
                    // is honest, where a full or arbitrary one would be a made-up reading.
                    if let fraction {
                        Capsule().fill(accent).frame(width: geo.size.width * fraction)
                    }
                }
            }
            .frame(height: 4)
            HStack {
                Text(MediaProgress.format(elapsed ?? 0))
                Spacer()
                if let duration = s.duration, duration > 0 { Text(MediaProgress.format(duration)) }
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue(progressDescription(elapsed: elapsed, duration: s.duration))
    }

    private func progressDescription(elapsed: Double?, duration: Double?) -> String {
        let position = MediaProgress.format(elapsed ?? 0)
        guard let duration, duration > 0 else { return position }
        return "\(position) of \(MediaProgress.format(duration))"
    }

    // MARK: - Transport

    /// Each control is gated on its own `supported_features` bit and **omitted** when unsupported,
    /// never shown disabled: a greyed button says "this device could do this, but not now", which
    /// is a different and false statement.
    @ViewBuilder
    private func transport(_ s: MediaPlayerState?, accent: Color) -> some View {
        if let s, s.features.contains(.previousTrack) || s.showsPlayPause || s.features.contains(.nextTrack) {
            FacetCard {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if s.features.contains(.previousTrack) {
                        transportButton("backward.end.fill", label: "Previous track", size: 22, accent: accent) {
                            store.mediaPreviousTrack(entityId)
                        }
                    }
                    if s.showsPlayPause {
                        Button { store.mediaPlayPause(entityId) } label: {
                            Image(systemName: s.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 52))
                                .foregroundStyle(accent)
                                .symbolRenderingMode(.hierarchical)
                                .padding(.horizontal, 18)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(s.isPlaying ? "Pause" : "Play")
                    }
                    if s.features.contains(.nextTrack) {
                        transportButton("forward.end.fill", label: "Next track", size: 22, accent: accent) {
                            store.mediaNextTrack(entityId)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func transportButton(_ symbol: String, label: String, size: CGFloat,
                                 accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: size + 22, height: size + 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Volume

    @ViewBuilder
    private func volume(_ s: MediaPlayerState?, accent: Color) -> some View {
        if let s, s.features.contains(.volumeSet) || s.features.contains(.volumeMute) {
            let live = Double(s.volumePercent ?? 0)
            FacetCard(title: "Volume") {
                HStack(spacing: 10) {
                    if s.features.contains(.volumeMute) {
                        Button { store.setMediaMuted(entityId, muted: !s.isMuted) } label: {
                            Image(systemName: s.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(s.isMuted ? HavenColor.warning : accent)
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(s.isMuted ? "Unmute" : "Mute")
                    }
                    if s.features.contains(.volumeSet) {
                        Slider(value: Binding(get: { dragVolume ?? live }, set: { dragVolume = $0 }),
                               in: 0...100,
                               onEditingChanged: { editing in
                                   if !editing, let v = dragVolume {
                                       store.setMediaVolume(entityId, percent: Int(v.rounded()))
                                       // Safe to clear immediately, unlike the light modal's
                                       // brightness slider: `setMediaVolume` writes the optimistic
                                       // `volume_level` into `states` synchronously, so `live` has
                                       // already caught up by the time this line runs.
                                       dragVolume = nil
                                   }
                               })
                        .tint(accent)
                        .accessibilityLabel("Volume")
                        .accessibilityValue(s.isMuted ? "Muted" : "\(Int((dragVolume ?? live).rounded()))%")
                        .accessibilityAdjustableAction { direction in
                            let current = dragVolume ?? live
                            let next = direction == .increment ? min(100, current + 5) : max(0, current - 5)
                            store.setMediaVolume(entityId, percent: Int(next.rounded()))
                            dragVolume = nil
                        }
                    }
                }
            }
        }
    }

    // MARK: - Source

    /// Segmented up to four options, a menu beyond — a receiver with a dozen inputs in a segmented
    /// control gives each one about three points of width.
    @ViewBuilder
    private func source(_ s: MediaPlayerState?, accent: Color) -> some View {
        if let s, s.features.contains(.selectSource), s.sourceList.count > 1 {
            FacetCard(title: "Source") {
                if s.sourceList.count <= 4 {
                    HavenSegmented(options: s.sourceList,
                                   selection: Binding(get: { s.source ?? s.sourceList[0] },
                                                      set: { store.selectMediaSource(entityId, source: $0) }),
                                   label: { $0 }, accent: accent)
                } else {
                    Menu {
                        ForEach(s.sourceList, id: \.self) { option in
                            Button(option) { store.selectMediaSource(entityId, source: option) }
                        }
                    } label: {
                        HStack {
                            Text(s.source ?? "Select a source").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(accent)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 12).fill(HavenColor.glassFill))
                    }
                    .accessibilityLabel("Source")
                    .accessibilityValue(s.source ?? "None selected")
                }
            }
        }
    }
}
