import SwiftUI

/// A compact draggable level control for a **tile**: a hairline track with a small pip on it.
///
/// It exists because the tiles cannot use the full-size `Slider` the modals do — that control is
/// taller than a tile's whole volume row, and far wider than the 4pt strip down the side of a 1×1 —
/// but the *contract* is deliberately identical to the light modal's brightness slider, so the two
/// cannot drift:
///
/// - a local `dragPercent` holds the preview and is the only thing that moves during a drag;
/// - the command is sent **once, on release**, never per frame (a WebSocket call per pixel of
///   travel is not a kind thing to do to someone's Home Assistant);
/// - `.accessibilityAdjustableAction` performs the same commit, so the control is operable without
///   the gesture at all.
///
/// ## Why the gesture is on the pip and not on the track
///
/// A tile is already covered by gestures that matter more: a tap that toggles or opens the modal,
/// and a long press. A track-wide, tap-to-set slider inside one would mean a stray tap silently
/// changing the volume of a speaker in another room — which is why the tiles carried *static*
/// readouts until now. So the drag target is the pip alone, and the value is driven by the
/// **translation of the drag**, not by the absolute position of the finger.
///
/// That combination is what makes a tap safe by construction rather than by a threshold: a touch
/// that lands on the pip and doesn't travel produces a translation of zero, and zero translation is
/// zero change. There is no minimum-distance heuristic to tune and no jump-to-finger to suppress —
/// the value simply cannot move unless the finger does. Dragging is also unbounded by the track's
/// length, so the user can carry on past either end to pin 0 or 100 rather than having to release
/// precisely on a short strip.
///
/// ## `onTap`, and the moving dead zone it exists to prevent
///
/// The pip's touch target has to be much larger than the pip is drawn, and on a 1×1 tile there is
/// nowhere for that target to go except *over the tile itself*. Since the drag gesture claims those
/// touches, the target would otherwise be a hole in the tile's own tap-to-toggle — and a hole that
/// **moves**, because it follows the pip up and down as the level changes. A tile where tapping
/// sometimes toggles the light and sometimes does nothing, depending on how bright it currently is,
/// is the kind of fiddliness that makes a control feel broken without ever looking wrong.
///
/// So a touch that ends with negligible travel is forwarded to `onTap`, and the tiles pass the same
/// action their own tap performs. The hole closes: tapping the pip does exactly what tapping
/// anywhere else on the tile does. Callers that want the control inert to taps — the media tiles,
/// whose volume row was never tap-to-open — simply leave it `nil`.
struct PipSlider: View {
    enum Axis {
        /// A horizontal track that fills from the leading edge. 0 at the left, 100 at the right.
        case horizontal
        /// A vertical track that fills from the bottom, matching the level bars it replaces —
        /// 0 at the bottom, 100 at the top, so "more" is "up" as it is on any physical dimmer.
        case vertical
    }

    /// The live value, 0…100, from the entity. Ignored while a drag is in flight.
    let percent: Int
    let accent: Color
    var axis: Axis = .horizontal
    /// Draws the control in its inactive treatment and adds "muted" to the spoken value. The pip
    /// still sits at the **real** level rather than at zero.
    var isMuted: Bool = false
    /// The lowest value a drag may commit. `1` for a light, where committing 0 would ask Home
    /// Assistant to turn it off and make this control's own affordance vanish from under the
    /// finger; `0` everywhere else.
    var minimum: Int = 0
    let label: String
    /// Called on release and on an accessibility adjustment. Never called during a drag.
    let onCommit: (Int) -> Void
    /// Called instead of `onCommit` when a touch ends without meaningful travel. See the type's
    /// doc comment — this is what stops the touch target being a moving hole in the tile's own tap.
    var onTap: (() -> Void)?

    /// Non-nil only while dragging (or for the instant an adjustable action takes), exactly as
    /// `LightModal.dragPercent` is.
    @State private var dragPercent: Double?
    /// The value the current drag started from. Translation is applied to this rather than to the
    /// live value, so a state push arriving mid-drag can't shift the thing under the finger.
    @State private var dragOrigin: Double?

    private let pip: CGFloat = 10
    private let thickness: CGFloat = 4
    /// The pip's touch target, in both orientations — a 10pt pip is not a target, and on a 4pt
    /// track this is six times the width of the thing it grabs. Which of the two dimensions runs
    /// *along* the track is what the axis decides; see `alongExtent`.
    private let hitSize = CGSize(width: 26, height: 24)
    /// Below this much travel a touch is a tap, not a drag. It only ever chooses between `onTap`
    /// and `onCommit` — the *value* is translation-driven either way, so this threshold can never
    /// be the reason a tap does or doesn't change something.
    private let tapSlop: CGFloat = 3

    private var displayed: Double { dragPercent ?? Double(max(0, min(100, percent))) }
    private var fraction: CGFloat { CGFloat(displayed) / 100 }
    /// Dimmed while muted: the level is still true, it just isn't doing anything right now.
    private var fill: Color { isMuted ? HavenColor.warning.opacity(0.55) : accent }

    var body: some View {
        GeometryReader { geo in
            let length = axis == .horizontal ? geo.size.width : geo.size.height
            let travel = max(0, length - pip)
            let filled = max(pip / 2, fraction * travel + pip / 2)
            ZStack(alignment: axis == .horizontal ? .leading : .bottom) {
                Capsule().fill(HavenColor.levelTrack)
                Capsule().fill(fill)
                    .frame(width: axis == .horizontal ? filled : nil,
                           height: axis == .vertical ? filled : nil)
                Circle()
                    .fill(fill)
                    .frame(width: pip, height: pip)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    .frame(width: hitSize.width, height: hitSize.height)
                    .contentShape(Rectangle())
                    // Clamped to the control's own bounds *along* the track: the touch target is far
                    // larger than the pip, so at either end an unclamped offset would put its edge
                    // outside the track — far enough, on the media tile, to eat the edge of the mute
                    // button 7pt away. Across the track it is deliberately not clamped, because a
                    // 4pt-wide bar has nowhere to put a 26pt target; that overhang is precisely why
                    // `onTap` exists.
                    .offset(x: axis == .horizontal ? alongOffset(travel: travel, length: length) : 0,
                            y: axis == .vertical ? -alongOffset(travel: travel, length: length) : 0)
                    .gesture(drag(travel: travel))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The control occupies exactly the space the static bar it replaces did — 4pt wide for the
        // vertical one, 24pt tall for the horizontal one — so no tile's layout or height changes.
        .frame(width: axis == .vertical ? thickness : nil,
               height: axis == .horizontal ? hitSize.height : nil)
        // Not `.accessibilityHidden` — these were static readouts the tile's own label already
        // described, and that was right for a readout. A *control* a VoiceOver user cannot reach or
        // change is worse than an unlabelled one.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spokenValue)
        .accessibilityAdjustableAction { direction in
            let next = direction == .increment ? min(100, displayed + 5) : max(Double(minimum), displayed - 5)
            commit(next)
        }
    }

    /// How much of the touch target runs along the track — its width when the track is horizontal,
    /// its height when vertical.
    private var alongExtent: CGFloat { axis == .horizontal ? hitSize.width : hitSize.height }

    /// Offset of the pip's touch target along the track, in points from the filled end.
    private func alongOffset(travel: CGFloat, length: CGFloat) -> CGFloat {
        min(max(0, fraction * travel - (alongExtent - pip) / 2), max(0, length - alongExtent))
    }

    /// The level is spoken either way — it is what an adjustment changes, and a value of just
    /// "Muted" would leave a VoiceOver user adjusting a number they can't hear.
    private var spokenValue: String {
        let level = "\(Int(displayed.rounded()))%"
        return isMuted ? "\(level), muted" : level
    }

    private func drag(travel: CGFloat) -> some Gesture {
        // `minimumDistance: 0` so the pip responds the instant it is touched — the "tapped and
        // dragged on" feel — which is safe only because the value is translation-driven.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let origin = dragOrigin ?? displayed
                if dragOrigin == nil { dragOrigin = origin }
                guard travel > 0 else { return }
                // Vertical is inverted: dragging *up* is a negative translation and more level.
                let moved = axis == .horizontal ? value.translation.width : -value.translation.height
                let delta = Double(moved / travel) * 100
                dragPercent = min(100, max(Double(minimum), origin + delta))
            }
            .onEnded { value in
                dragOrigin = nil
                let travelled = hypot(value.translation.width, value.translation.height)
                guard travelled > tapSlop else {
                    // A tap, not a drag. Discard the preview (it never moved anywhere) and hand the
                    // touch to the tile, so the target isn't a hole in the tile's own tap area.
                    dragPercent = nil
                    onTap?()
                    return
                }
                guard let level = dragPercent else { return }
                commit(level)
            }
    }

    private func commit(_ value: Double) {
        onCommit(Int(value.rounded()))
        // Cleared immediately, and that is safe because every command behind this control writes
        // its optimistic state into `states` synchronously (`MediaPlayerOptimistic`,
        // `LightOptimistic`, `CoverOptimistic`), so `percent` has already caught up by the time this
        // line runs. Without that, clearing here would be exactly the snap-back D spec §10b item 2
        // describes — which is why those three helpers are a prerequisite for this control rather
        // than a nicety alongside it.
        dragPercent = nil
    }
}
