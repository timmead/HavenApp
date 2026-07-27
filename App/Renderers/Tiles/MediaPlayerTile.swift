import SwiftUI
import HavenCore

/// The three approved media-player tile renderings. Which one a surface uses is a per-surface
/// constant, never a function of state: a tile that changed size when playback started would have
/// to migrate between two different `LazyVGrid`s — `.gridCellColumns` is inert inside one (D spec
/// §10a) — so the entity would visibly jump between grid sections every time a song began.
enum MediaTileSize {
    /// 1×1. A centred play/pause and the name beneath it.
    case small
    /// 2×1. No artwork: the title takes the artwork's place, in a scrolling window.
    case wide
    /// 4×2. Artwork down the whole left side with the transport over it; text and volume right.
    case large
}

/// **No size is a pure launcher.** Every one of the three carries at least play/pause, because a
/// media tile whose only action is "open the modal" is a label, and the thing you want from across
/// the room is to stop the music.
struct MediaPlayerTile: View {
    let entityId: String
    var size: MediaTileSize = .small
    @Environment(HomeStore.self) private var store

    var body: some View {
        let e = store.state(entityId)
        let s = e.map(MediaPlayerState.init)
        let name = TileName.of(entityId, e)
        Group {
            switch size {
            case .small: small(s, name: name)
            case .wide: wide(s, name: name)
            case .large: large(s, name: name, deviceClass: e?.deviceClass)
            }
        }
        .onLongPressGesture(minimumDuration: 0.35) { store.presented = entityId }
        // `.contain`, not `.combine`: these tiles hold real buttons, and combining would fold them
        // into a single label a VoiceOver user could read but not operate. The label below is the
        // container's, spoken on entry, and each button keeps its own.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(s.map { AccessibilitySummary.mediaPlayer(name, $0) } ?? name)
        .accessibilityAction(named: "Open controls") { store.presented = entityId }
    }

    // MARK: - 1×1

    private func small(_ s: MediaPlayerState?, name: String) -> some View {
        GlassTile(active: s?.isPlaying ?? false, accent: accent) {
            VStack(spacing: 4) {
                Spacer(minLength: 0)
                playPauseButton(s, size: 26)
                Spacer(minLength: 0)
                Text(name)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle((s?.isActive ?? false) ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
    }

    // MARK: - 2×1

    private func wide(_ s: MediaPlayerState?, name: String) -> some View {
        GlassTile(active: s?.isPlaying ?? false, accent: accent) {
            // `spacing: 0` with a `Spacer` between the two rows, rather than a spaced `VStack`:
            // a `VStack(spacing: 6)` over three children adds *two* 6pt gaps, which would push the
            // ideal height to 72 and grow the tile past the floor — the exact state-dependent
            // resize the note below rules out. Here the gap is whatever slack is left over, so the
            // ideal is 60, the floor of 66 wins, and the height is identical in both states.
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    // Deliberately no artwork at this size — the approved design gives the artwork's
                    // place to the title, because at two columns a thumbnail and an ellipsised track
                    // name answer "what's playing?" less well than the whole track name does.
                    ScrollingText(
                        text: s?.title ?? name,
                        secondary: s?.secondaryLine,
                        windowHeight: 30
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { store.presented = entityId }
                    // The speaker joins the transport row rather than sitting below it. There was
                    // visible horizontal slack between the title and the buttons — a 2×1 title is
                    // usually short — and a 24pt glyph is exactly what that slack is good for.
                    // Moving it up also hands the whole bottom line to the level track, which is
                    // the part that benefits from every point of width it can get.
                    muteButton(s, size: 13)
                    playPauseButton(s, size: 22)
                    if s?.features.contains(.nextTrack) ?? false {
                        transportButton("forward.end.fill", label: "Next track", size: 15) {
                            store.mediaNextTrack(entityId)
                        }
                    }
                }
                // **This occupies space the tile already reserved; it does not claim any.**
                // `GlassTile` floors its content at 66pt aligned to the top, while the row above is
                // about 36pt tall — so roughly 30pt has always sat empty at the bottom of a 2×1.
                // A 4pt track leaves the ideal at 40, well under that floor, so the tile's height
                // is unchanged whether it is playing or not.
                //
                // Staying under the floor is the point, not a nicety. This file opens by arguing
                // that a media tile must not change size as a function of state — and a 2×1 that
                // grew when playback started would resize every other tile sharing its grid row,
                // on every song. So the space is *reserved* and merely filled when there is
                // something to put in it, never grown into. The title window is untouched either
                // way, which is what keeps the scrolling-overflow behaviour it exists for.
                Spacer(minLength: 0)
                // Omitted, never disabled, on a player that didn't declare `volume_set` — and only
                // while playing, which is when a level is worth the line.
                if let s, s.isPlaying, s.features.contains(.volumeSet) {
                    PipSlider(percent: s.volumePercent ?? 0, accent: accent, isMuted: s.isMuted,
                              label: "Volume") { percent in
                        store.setMediaVolume(entityId, percent: percent)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 4×2

    private func large(_ s: MediaPlayerState?, name: String, deviceClass: String?) -> some View {
        // Two tile rows plus the grid's own row spacing, so a 4×2 lines up with two rows of 1×1s.
        let height: CGFloat = 141
        return HStack(spacing: 0) {
            artwork(s, deviceClass: deviceClass)
                .frame(width: height, height: height)
                .clipped()
                .overlay(alignment: .bottom) { transportScrim(s) }
                .contentShape(Rectangle())
                .onTapGesture { store.presented = entityId }
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s?.title ?? name)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(2)
                        .foregroundStyle((s?.isActive ?? false) ? .primary : .secondary)
                    if let secondary = s?.secondaryLine {
                        Text(secondary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(s?.playback.label ?? "Unavailable")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { store.presented = entityId }
                Spacer(minLength: 0)
                volumeRow(s)
            }
            .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(height: height)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill((s?.isPlaying ?? false) ? AnyShapeStyle(accent.opacity(0.30)) : AnyShapeStyle(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder((s?.isPlaying ?? false) ? accent.opacity(0.6) : HavenColor.glassStroke, lineWidth: 1))
                .shadow(color: (s?.isPlaying ?? false) ? accent.opacity(0.28) : .black.opacity(0.06),
                        radius: (s?.isPlaying ?? false) ? 10 : 3, y: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Artwork, or the domain icon on the accent when there is none — a radio stream has no cover
    /// art, and an empty grey rectangle reads as a failed load rather than as "no picture".
    @ViewBuilder
    private func artwork(_ s: MediaPlayerState?, deviceClass: String?) -> some View {
        AuthenticatedImage(path: s?.artworkPath) { phase in
            switch phase {
            case .image(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .loading, .empty, .failed:
                ZStack {
                    accent.opacity(0.28)
                    Image(systemName: IconMap.symbol(domain: .mediaPlayer, deviceClass: deviceClass))
                        .font(.system(size: 30))
                        .foregroundStyle(accent)
                        .symbolRenderingMode(.hierarchical)
                }
            }
        }
        .accessibilityHidden(true)      // the tile's own label already says what is playing
    }

    /// Prev / play-pause / next over a scrim on the bottom of the artwork. The scrim is what makes
    /// white controls legible over an arbitrary album cover, which can be any colour at all.
    @ViewBuilder
    private func transportScrim(_ s: MediaPlayerState?) -> some View {
        HStack(spacing: 14) {
            if s?.features.contains(.previousTrack) ?? false {
                transportButton("backward.end.fill", label: "Previous track", size: 13, tint: .white) {
                    store.mediaPreviousTrack(entityId)
                }
            }
            playPauseButton(s, size: 20, tint: .white)
            if s?.features.contains(.nextTrack) ?? false {
                transportButton("forward.end.fill", label: "Next track", size: 13, tint: .white) {
                    store.mediaNextTrack(entityId)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background {
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    /// A mute button plus a draggable level control, shared by the 2×1 and the 4×2 so the two
    /// behave alike.
    ///
    /// This was a static readout, on the grounds that a slider this small is a mis-tap waiting to
    /// happen next to a tap that opens the modal. That concern was real and is answered rather than
    /// dropped: `PipSlider` puts the gesture on the pip alone and drives the value from the drag's
    /// *translation*, so a touch that doesn't travel cannot change anything — see its doc comment.
    /// The fine control still exists in the modal too; this is the one you can reach from the grid.
    @ViewBuilder
    private func volumeRow(_ s: MediaPlayerState?) -> some View {
        if let s, s.isActive, s.features.contains(.volumeSet) || s.features.contains(.volumeMute) {
            HStack(spacing: 7) {
                muteButton(s, size: 12)
                // Only where the device declared `volume_set` — omitted, never shown disabled, like
                // every other control here. A player that can mute but not set a level keeps its
                // mute button and simply has no track beside it.
                if s.features.contains(.volumeSet) {
                    // The pip sits at the **real** level while muted rather than at zero. Muting in
                    // Home Assistant is independent of level — `MediaPlayerOptimistic.mute` goes out
                    // of its way to leave `volume_level` alone so un-muting restores the right
                    // volume — so parking the pip at zero would contradict the model and, worse,
                    // make a drag start from a value the speaker was never at.
                    PipSlider(percent: s.volumePercent ?? 0,
                              accent: accent,
                              isMuted: s.isMuted,
                              label: "Volume") { percent in
                        store.setMediaVolume(entityId, percent: percent)
                    }
                }
            }
        }
    }

    // MARK: - Shared controls

    private var accent: Color { HavenColor.domain(.mediaPlayer) }

    /// The speaker glyph: a mute toggle where the device declared `volume_mute`, and a plain
    /// indicator where it didn't.
    ///
    /// Its own helper because the 2×1 puts it in the transport row and the 4×2 keeps it beside the
    /// level track — two placements, one control, so a change to what muting looks like can't apply
    /// to only one of them. Nothing at all is drawn for an inactive or unknown player, so an off
    /// speaker doesn't carry a volume glyph it can't act on.
    @ViewBuilder
    private func muteButton(_ s: MediaPlayerState?, size: CGFloat) -> some View {
        if let s, s.isActive, s.features.contains(.volumeMute) {
            Button { store.setMediaMuted(entityId, muted: !s.isMuted) } label: {
                Image(systemName: s.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: size))
                    .foregroundStyle(s.isMuted ? HavenColor.warning : accent)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(s.isMuted ? "Unmute" : "Mute")
        } else if let s, s.isActive, s.features.contains(.volumeSet) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: size)).foregroundStyle(accent)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
        }
    }

    /// Drawn only where the device declared the matching half of play/pause — an unsupported
    /// control is omitted, never shown disabled. Where neither half exists, the tile still needs
    /// something in the middle, so the domain icon stands in as a non-interactive placeholder
    /// rather than leaving a hole the layout collapses around.
    @ViewBuilder
    private func playPauseButton(_ s: MediaPlayerState?, size: CGFloat, tint: Color? = nil) -> some View {
        if let s, s.showsPlayPause {
            Button { store.mediaPlayPause(entityId) } label: {
                Image(systemName: s.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: size))
                    .foregroundStyle(tint ?? accent)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: size + 14, height: size + 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(s.isPlaying ? "Pause" : "Play")
        } else {
            Image(systemName: "play.circle")
                .font(.system(size: size))
                .foregroundStyle(.secondary)
                .frame(width: size + 14, height: size + 14)
                .accessibilityHidden(true)
        }
    }

    private func transportButton(_ symbol: String, label: String, size: CGFloat,
                                 tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint ?? accent)
                .frame(width: size + 16, height: size + 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A fixed-height window over a title that may not fit, which scrolls slowly to its last line,
/// holds there, and returns.
///
/// **It animates only when the text actually overflows.** A short name sits perfectly still — a
/// tile whose text drifts for no reason is the kind of motion that makes a dashboard tiring to
/// look at, and it would be drawing attention to nothing.
///
/// Under Reduce Motion it clamps instead of animating: the window shows what fits and stops there.
/// That does lose the tail of a long title, which is the trade the setting asks for — the user has
/// said plainly that they would rather read less than watch something move, and the modal shows the
/// full title anyway.
private struct ScrollingText: View {
    let text: String
    var secondary: String?
    let windowHeight: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat = 0

    private var overflow: CGFloat { max(0, contentHeight - windowHeight) }

    var body: some View {
        // Measured with `overflow > 0.5` rather than `> 0` so a sub-pixel rounding difference
        // between the measured height and the window can't start an animation that travels a
        // fraction of a point — visually a shiver, and permanent.
        let scrolls = overflow > 0.5 && !reduceMotion
        return Group {
            if scrolls {
                KeyframeAnimator(initialValue: CGFloat.zero, repeating: true) { offset in
                    lines.offset(y: offset)
                } keyframes: { _ in
                    KeyframeTrack {
                        // Hold at the top long enough to read the first line before anything moves.
                        LinearKeyframe(CGFloat.zero, duration: 2.0)
                        // ~14pt/s: slow enough to read while it travels.
                        LinearKeyframe(-overflow, duration: Double(overflow / 14))
                        LinearKeyframe(-overflow, duration: 2.0)
                        // The return is a reset, not a read — twice the speed.
                        LinearKeyframe(CGFloat.zero, duration: Double(overflow / 28))
                    }
                }
                // Identity pinned to the text, so the scroll restarts from the top when the track
                // changes — and, more importantly, does *not* restart on every other body
                // evaluation. A media player's state is pushed frequently (position, volume,
                // buffering), and a title that jumped back to the top on each push would never
                // reach its last line, which is the one thing this view exists to do.
                .id(text)
            } else {
                lines
            }
        }
        .frame(height: windowHeight, alignment: .top)
        .clipped()
        // Spoken by the enclosing tile's combined label; a second reading of the same words while
        // swiping is noise.
        .accessibilityHidden(true)
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text).font(.system(size: 12.5, weight: .semibold))
            if let secondary {
                Text(secondary).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }
}
