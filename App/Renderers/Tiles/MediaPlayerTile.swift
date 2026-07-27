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
    /// Non-nil only while dragging the volume slider — the preview the drag moves, so no command
    /// goes out until the finger lifts. Exactly `MediaPlayerModal.dragVolume`.
    @State private var dragVolume: Double?

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
                    playPauseButton(s, size: 22)
                    if s?.features.contains(.nextTrack) ?? false {
                        transportButton("forward.end.fill", label: "Next track", size: 15) {
                            store.mediaNextTrack(entityId)
                        }
                    }
                }
                // **This occupies space the tile already reserved; it does not claim any.**
                // `GlassTile` floors its content at 66pt aligned to the top, while the row above is
                // about 36pt tall — so roughly 30pt has always sat empty at the bottom of a 2×1,
                // which is the gap the device screenshot shows. A 24pt volume strip brings the
                // ideal to 60, still under that floor, so the tile's height is unchanged whether it
                // is playing or not.
                //
                // Staying under the floor is the point, not a nicety. This file opens by arguing
                // that a media tile must not change size as a function of state — and a 2×1 that
                // grew when playback started would resize every other tile sharing its grid row,
                // on every song. So the space is *reserved* and merely filled when there is
                // something to put in it, never grown into. The title window is untouched either
                // way, which is what keeps the scrolling-overflow behaviour it exists for.
                Spacer(minLength: 0)
                if s?.isPlaying ?? false {
                    // `volumeRow` already draws nothing at all for a player that declares neither
                    // `volumeSet` nor `volumeMute`, so an unsupported device gets empty space rather
                    // than a dead track — the same omit-don't-disable rule the transport follows.
                    volumeRow(s)
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

    /// A mute button plus a volume slider, shared by the 2×1 and the 4×2 so the two behave alike.
    ///
    /// It is a **stock `Slider`**, deliberately: this row is horizontal and ~100pt wide, which is a
    /// shape SwiftUI already ships a control for, and `MediaPlayerModal` has always drawn its volume
    /// this way. Writing a second one by hand bought nothing but the chance to get gesture handling
    /// wrong. (`PipSlider` still exists for the light and shade tiles, where the control is a 4pt
    /// vertical strip and there is no native equivalent at all — see its doc comment.)
    ///
    /// Two things the stock control does not give away for free and this keeps:
    ///
    /// - **the command goes out once, on release**, via `onEditingChanged` — never per frame, which
    ///   would be a WebSocket call per pixel of travel;
    /// - the adjustable action **commits**. `Slider`'s own increment/decrement drives the binding,
    ///   which here only moves `dragVolume` and would never send anything at all.
    ///
    /// The mis-tap worry that kept this a static readout — a slider next to a tap that opens the
    /// modal — does not arise here, because nothing in either tile size makes the volume row
    /// tap-to-open. `wide()` puts that gesture on the title alone and `large()` on the artwork and
    /// the text; the row has no tile gesture underneath it, so the slider is not a hole in one.
    @ViewBuilder
    private func volumeRow(_ s: MediaPlayerState?) -> some View {
        if let s, s.isActive, s.features.contains(.volumeSet) || s.features.contains(.volumeMute) {
            HStack(spacing: 7) {
                if s.features.contains(.volumeMute) {
                    Button {
                        store.setMediaMuted(entityId, muted: !s.isMuted)
                    } label: {
                        Image(systemName: s.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(s.isMuted ? HavenColor.warning : accent)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(s.isMuted ? "Unmute" : "Mute")
                } else {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 12)).foregroundStyle(accent)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                }
                // Only where the device declared `volume_set` — omitted, never shown disabled, like
                // every other control here. A player that can mute but not set a level keeps its
                // mute button and simply has no track beside it.
                if s.features.contains(.volumeSet) {
                    // The thumb sits at the **real** level while muted rather than at zero. Muting
                    // in Home Assistant is independent of level — `MediaPlayerOptimistic.mute` goes
                    // out of its way to leave `volume_level` alone so un-muting restores the right
                    // volume — so parking it at zero would contradict the model and, worse, make a
                    // drag start from a value the speaker was never at. The muted *treatment* is
                    // therefore the tint alone: dimmed because it isn't doing anything right now,
                    // not moved, because the number is still true.
                    volumeSlider(s)
                }
            }
        }
    }

    /// The volume control itself, written to match `MediaPlayerModal.volume` line for line — same
    /// preview state, same commit-on-release, same adjustable action — so the two cannot drift.
    private func volumeSlider(_ s: MediaPlayerState) -> some View {
        let live = Double(s.volumePercent ?? 0)
        return Slider(value: Binding(get: { dragVolume ?? live }, set: { dragVolume = $0 }),
                      in: 0...100,
                      onEditingChanged: { editing in
                          if !editing, let v = dragVolume {
                              store.setMediaVolume(entityId, percent: Int(v.rounded()))
                              // Safe to clear immediately: `setMediaVolume` writes the optimistic
                              // `volume_level` into `states` synchronously, so `live` has already
                              // caught up by the time this line runs. Without that this would be
                              // the snap-back D spec §10b item 2 describes.
                              dragVolume = nil
                          }
                      })
        // **The row's height is stated, not inherited, and the tile depends on it.** A `Slider`'s
        // intrinsic height is about 33pt; the mute button beside it is 24, which is what `wide()`
        // above budgeted for when it argued that the volume strip brings the 2×1's ideal height to
        // 60 and so stays under `GlassTile`'s 66pt floor. Let the slider size itself and the ideal
        // goes to ~69, the floor stops winning, and the tile grows the moment playback starts —
        // exactly the state-dependent resize this file opens by ruling out. The 28pt thumb
        // overhangs this frame by a couple of points and is not clipped, which is only a drawing
        // detail; the layout is 24.
        .frame(height: 24)
        .tint(s.isMuted ? HavenColor.warning.opacity(0.55) : accent)
        .accessibilityLabel("Volume")
        .accessibilityValue(s.isMuted ? "Muted" : "\(Int((dragVolume ?? live).rounded()))%")
        .accessibilityAdjustableAction { direction in
            let current = dragVolume ?? live
            let next = direction == .increment ? min(100, current + 5) : max(0, current - 5)
            store.setMediaVolume(entityId, percent: Int(next.rounded()))
            dragVolume = nil
        }
    }

    // MARK: - Shared controls

    private var accent: Color { HavenColor.domain(.mediaPlayer) }

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
