import SwiftUI
import HavenCore

/// The three approved media-player tile renderings. Which one a surface uses is a per-surface
/// constant, never a function of state: `RoomGrid` places every tile in a subsection at that
/// subsection's one span (`RoomSubsection.span`, the household's own choice for Media), so a tile
/// that changed size when playback started would be a tile resizing itself out from under the grid
/// mid-render — the entity would visibly reflow its subsection every time a song began.
enum MediaTileSize {
    /// 2×1. No artwork: the title takes the artwork's place, in a scrolling window.
    case wide
    /// 4×1. One line the width of the room: icon, the title in the same scrolling window, and the
    /// whole transport on the right.
    case row
    /// 4×2. Artwork down the whole left side with the transport over it; text and volume right.
    case large
}

/// **No size is a pure launcher.** Every one of the three carries at least play/pause, because a
/// media tile whose only action is "open the modal" is a label, and the thing you want from across
/// the room is to stop the music.
///
/// That rule is why there is no 1×1 any more. There was one — a centred play/pause with the name
/// under it — and it obeyed the rule by the narrowest possible margin: it was the only size that
/// could not also say *what was playing*, because a quarter-width tile fits a button or a track
/// name and not both. Withdrawing it (tile refinements, item 3) made the 2×1 the smallest media
/// tile and left the rule holding with room to spare at every remaining size.
struct MediaPlayerTile: View {
    let entityId: String
    /// The smallest rendering, matching `MediaTileSize(span:)`'s own fallback — so a caller with no
    /// opinion and a span with no rendering land in the same place.
    var size: MediaTileSize = .wide
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation
    /// Which surface this tile is on — set by `ConfigurableTile`, and what a tap in
    /// configuration mode removes it from.
    @Environment(\.havenSurface) private var surface
    /// Non-nil only while dragging the volume slider — the preview the drag moves, so no command
    /// goes out until the finger lifts. Held here rather than inside `CommitSlider` for the reason
    /// that type's doc comment gives: the clearing signal differs per call site, and this one has
    /// none.
    @State private var dragVolume: Double?

    var body: some View {
        let e = store.state(entityId)
        let s = e.map(MediaPlayerState.init)
        let name = store.displayName(of: entityId)
        let unavailable = e?.isUnavailable ?? false
        // Kept separate from `name` deliberately: `name` still feeds the accessibility label two
        // lines down regardless of this toggle, so nothing here nils it out — that would silence
        // VoiceOver's identification of the tile along with the on-screen text.
        let labelHidden = store.labelHidden(of: entityId)
        Group {
            switch size {
            case .wide: wide(s, name: name, unavailable: unavailable, labelHidden: labelHidden)
            case .row: row(s, name: name, deviceClass: e?.deviceClass,
                           unavailable: unavailable, labelHidden: labelHidden)
            case .large: large(s, name: name, deviceClass: e?.deviceClass, labelHidden: labelHidden)
            }
        }
        .onLongPressGesture(minimumDuration: 0.35) { navigation.open(entityId, on: surface) }
        // `.contain`, not `.combine`: these tiles hold real buttons, and combining would fold them
        // into a single label a VoiceOver user could read but not operate. The label below is the
        // container's, spoken on entry, and each button keeps its own.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(s.map { AccessibilitySummary.mediaPlayer(name, $0) } ?? name)
        .accessibilityAction(named: "Open controls") { navigation.open(entityId, on: surface) }
    }

    // MARK: - 2×1

    private func wide(_ s: MediaPlayerState?, name: String, unavailable: Bool,
                      labelHidden: Bool) -> some View {
        GlassTile(active: s?.isPlaying ?? false, accent: accent, unavailable: unavailable) {
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
                    //
                    // **The fallback to `name` is itself the visible name.** A player reporting no
                    // title has nothing else to show here, so a hidden label falls back to an empty
                    // string rather than the device's name — the one spot on this tile where "no
                    // title" and "no label" would otherwise look identical and only one of them is
                    // the household's choice to have made.
                    ScrollingText(
                        text: s?.title ?? (labelHidden ? "" : name),
                        secondary: s?.secondaryLine,
                        windowHeight: 30,
                        unavailable: unavailable
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { navigation.open(entityId, on: surface) }
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

    // MARK: - 4×1

    /// **The extra two columns go entirely to controls.** The 2×1 fits the title and one-and-a-bit
    /// buttons; given the whole width, this size spends what it gains on a real transport —
    /// previous, play/pause, next — rather than on artwork or a volume slider. One row's worth of
    /// the things you do from across the room, which is the only reason to give a row to a speaker.
    ///
    /// **It takes its own height, and it must keep taking it.** Unlike `large()` below, a 4×1 is a
    /// *single-row* span, and single-row is the one case both hosts size by measurement rather than
    /// by proposal: `RoomGrid.rowHeight` measures `sizeThatFits(.unspecified)` on single-row
    /// subviews and hands the tallest one's height to every row, and `SubsectionView.tileHeight`
    /// returns nil for a single row so each tile asks for what it wants. A `maxHeight: .infinity`
    /// here would therefore be greedy rather than exact — the trap `SubsectionView.tileHeight`'s
    /// comment records having fallen into and removed — which is the exact opposite of what
    /// `large()` and `CameraTile.wide` need. Same file, opposite rules, because the spans differ.
    ///
    /// The height is also identical in every playback state, which this file's opening argument
    /// requires: the tallest thing on the line is the 22pt play/pause in its 36pt frame, well under
    /// `GlassTile`'s 66pt content floor, and there is no volume strip to appear when playback
    /// starts. That matters more here than anywhere else — a Media subsection sizes all its tiles
    /// alike, so this tile *is* the measured row height for the whole container.
    private func row(_ s: MediaPlayerState?, name: String, deviceClass: String?,
                     unavailable: Bool, labelHidden: Bool) -> some View {
        // `.leading` — horizontally leading, vertically centred. A single line hung from the top of
        // an 85pt tile floats over 30pt of nothing; `wide()` above can sit at the top because it has
        // a second row to put in that space and this size deliberately does not.
        GlassTile(active: s?.isPlaying ?? false, accent: accent, unavailable: unavailable,
                  alignment: .leading) {
            HStack(spacing: 10) {
                // What the 2×1 has no width for and the 4×2 spends a whole square on: at a glance
                // across a room, the thing that says "speaker" before you have read anything.
                Image(systemName: IconMap.symbol(domain: .mediaPlayer, deviceClass: deviceClass))
                    .font(.system(size: 20))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Emphasis.accent.color(unavailable: unavailable, accent: accent))
                    .frame(width: 26)
                    // The tile's own label already names the device and says what it is playing.
                    .accessibilityHidden(true)
                // **The same window and the same fallback as `wide()`, deliberately including the
                // empty string.** `large()` uses `if let` because its title block sizes to its own
                // content, so a blank line would still claim a line box; here the title sits in a
                // fixed 30pt `ScrollingText` window inside a *horizontal* row, so its height never
                // reaches the tile's at all and blank and absent occupy identical space. Forking the
                // two `ScrollingText` call sites' idiom would buy nothing but a difference to
                // explain. The fallback itself is the rule Task 2 set: a hidden label falls back to
                // no title rather than to the device's name, because this slot is where the visible
                // name actually shows and falling back to it would put it straight back on screen.
                ScrollingText(
                    text: s?.title ?? (labelHidden ? "" : name),
                    secondary: s?.secondaryLine,
                    windowHeight: 30,
                    unavailable: unavailable
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { navigation.open(entityId, on: surface) }
                // Tight spacing because each button already carries a 16pt-larger tap frame than its
                // glyph: the gaps you see are those frames, and a stated gap on top of them would
                // push the cluster off the right of the tile rather than space it.
                transportCluster(s, playPause: 22, sides: 15, spacing: 2)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 4×2

    // Deliberately not struck when unavailable. Unlike `wide()` and `row()`, this size does
    // not route through `GlassTile` at all — it is a full-bleed `HStack` with its own artwork,
    // scrim, and background, structurally the same shape as `CameraTile`. Giving it a strike
    // would mean designing a treatment for a different surface, not passing a flag to an
    // existing one, which is out of scope here.
    private func large(_ s: MediaPlayerState?, name: String, deviceClass: String?,
                       labelHidden: Bool) -> some View {
        HStack(spacing: 0) {
            // **A square of whatever height the grid gave the tile, with no number of its own.**
            // This used to be `.frame(width: 141, height: 141)` inside an outer `.frame(height:
            // 141)` — "two tile rows plus the grid's own row spacing" — which is the same constant
            // and the same mistake `CameraTile.wide` now records: 141 assumes `GlassTile`'s 66pt
            // floor for a two-row cell, and a real two-row cell measures nearer 173, so a 4×2 media
            // tile drew a full 32pt shorter than the two rows it claims to occupy.
            // `RoomGrid.fallbackRowHeight`'s doc comment names that very constant as the trap the
            // grid exists to have escaped; the two tiles that hard-coded it are now both fixed.
            //
            // `aspectRatio(1, contentMode: .fit)` resolves the square from the height this row is
            // given rather than from a literal, so the artwork grows with the cell. As with
            // `CameraTile.wide`, the dependency is now the structural inverse of the old bug: the
            // tile needs an *exact* height proposal, and against an unbounded one `.fit` would
            // resolve from the child instead — a resizable image with no opinion worth having.
            // Both hosts give an exact one for a multi-row span (`RoomGrid.placeSubviews` directly,
            // `SubsectionView`'s scroll body via `unmeasuredHeight(for:)`), so a 4×2 media tile must
            // not be placed anywhere else.
            artwork(s, deviceClass: deviceClass)
                .aspectRatio(1, contentMode: .fit)
                .clipped()
                .overlay(alignment: .bottom) { transportScrim(s) }
                .contentShape(Rectangle())
                .onTapGesture { navigation.open(entityId, on: surface) }
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    // Same rule as `wide()`'s title fallback: a hidden label falls back to no
                    // title, not to the device's name, so "nothing is playing" and "the name is
                    // hidden" cannot be mistaken for each other here. Unlike `wide()`'s fixed-height
                    // `ScrollingText`, this block sizes to its own content, so — the same
                    // absent-not-blanked rule `TileLabel`/`StateFace` apply — an `if let` rather
                    // than an empty string: a blank bold line would still claim its own line box
                    // above the playback word for no visible text.
                    if let title = s?.title ?? (labelHidden ? nil : name) {
                        Text(title)
                            .font(.system(size: 14, weight: .bold))
                            .lineLimit(2)
                            .foregroundStyle((s?.isActive ?? false) ? .primary : .secondary)
                    }
                    if let secondary = s?.secondaryLine {
                        Text(secondary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(s?.playback.label ?? "Unavailable")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { navigation.open(entityId, on: surface) }
                Spacer(minLength: 0)
                volumeRow(s)
            }
            .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// Previous / play-pause / next — the whole transport, drawn by the two sizes that have room
    /// for one: on the right of `row()`'s line, and over `large()`'s artwork scrim.
    ///
    /// **Shared for the omission rules rather than for the `HStack`.** Each side button is drawn
    /// only where the device declared its feature bit, and `playPauseButton` has its own branch for
    /// a device that declared neither half — an unsupported control is omitted, never shown
    /// disabled. Two copies of a layout would be tedious; two copies of *what a device can do*
    /// would be somewhere for the answer to fall out of step, and the `.wide` size below is already
    /// a third, deliberately cut-down set (play-pause and next only, because two columns is what it
    /// has). Sizes stay parameters because the call sites are drawn at different scales over
    /// different backgrounds — white over an album cover, the domain accent on glass.
    private func transportCluster(_ s: MediaPlayerState?, playPause: CGFloat, sides: CGFloat,
                                  spacing: CGFloat, tint: Color? = nil) -> some View {
        HStack(spacing: spacing) {
            if s?.features.contains(.previousTrack) ?? false {
                transportButton("backward.end.fill", label: "Previous track", size: sides, tint: tint) {
                    store.mediaPreviousTrack(entityId)
                }
            }
            playPauseButton(s, size: playPause, tint: tint)
            if s?.features.contains(.nextTrack) ?? false {
                transportButton("forward.end.fill", label: "Next track", size: sides, tint: tint) {
                    store.mediaNextTrack(entityId)
                }
            }
        }
    }

    /// The transport over a scrim on the bottom of the artwork. The scrim is what makes white
    /// controls legible over an arbitrary album cover, which can be any colour at all.
    private func transportScrim(_ s: MediaPlayerState?) -> some View {
        transportCluster(s, playPause: 20, sides: 13, spacing: 14, tint: .white)
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

    /// The volume control itself: `CommitSlider`, the same component the media modal's volume, the
    /// light modal's brightness and colour temperature, and the cover modal's position are all
    /// drawn with. The preview state, the commit-on-release and the adjustable action live there,
    /// which is what stops this and `MediaPlayerModal.volume` drifting apart — they used to be kept
    /// in step by hand, and by a comment asking whoever edited one to edit the other.
    private func volumeSlider(_ s: MediaPlayerState) -> some View {
        let live = Double(s.volumePercent ?? 0)
        return CommitSlider(value: live, preview: $dragVolume, in: 0...100,
                            adjustmentStep: 5,
                            tint: s.isMuted ? HavenColor.warning.opacity(0.55) : accent,
                            label: "Volume",
                            valueDescription: { s.isMuted ? "Muted" : "\(Int($0.rounded()))%" },
                            onCommit: { store.setMediaVolume(entityId, percent: Int($0.rounded())) })
        // **The row's height is stated, not inherited, and the tile depends on it.** A `Slider`'s
        // intrinsic height is about 33pt; the mute button beside it is 24, which is what `wide()`
        // above budgeted for when it argued that the volume strip brings the 2×1's ideal height to
        // 60 and so stays under `GlassTile`'s 66pt floor. Let the slider size itself and the ideal
        // goes to ~69, the floor stops winning, and the tile grows the moment playback starts —
        // exactly the state-dependent resize this file opens by ruling out. The 28pt thumb
        // overhangs this frame by a couple of points and is not clipped, which is only a drawing
        // detail; the layout is 24.
        .frame(height: 24)
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
    /// Had no `foregroundStyle` at all on the main line, which defaults to `.primary` regardless
    /// of reachability — its callers, `MediaPlayerTile.wide()` and `.row()`, each thread their own
    /// `unavailable` through here rather than leaving this window as the one text element on the
    /// tile the strike didn't reach. `large()` has its own title `Text` and does not use this
    /// view — see its doc comment for why it stays out of this feature entirely.
    var unavailable: Bool = false

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
                .foregroundStyle(Emphasis.primary.color(unavailable: unavailable, accent: .gray))
            if let secondary {
                Text(secondary).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }
}

extension MediaTileSize {
    /// The rendering a span asks for. See `DeviceTileView.tile` — this is half of the one place
    /// where a number of cells becomes a drawing.
    ///
    /// The three cases are exactly `TileSpan.available(for: .mediaPlayer)`, listed in the same
    /// order, so the two can be read against each other — that list's own rule is that nothing is
    /// offered which cannot be drawn.
    ///
    /// **The fallback is `.wide`, the smallest**, and it used to be a 1×1 that no longer exists. It
    /// is reachable in one real way: a household that stored `1x1` for its Media subsection under a
    /// build that still offered it. That is a size decision Haven has withdrawn, not a document to
    /// discard, so the tile draws at the smallest rendering it does have rather than not at all.
    init(span: TileSpan) {
        switch (span.columns, span.rows) {
        case (2, 1): self = .wide
        case (4, 1): self = .row
        case (4, 2): self = .large
        default: self = .wide
        }
    }
}
