import SwiftUI

/// A vertical draggable level control for a **tile**: a hairline column with a small pip on it.
///
/// ## Why this is custom, when the horizontal case is not
///
/// The media tiles' volume row is a stock `Slider`, as the media modal's has always been — a
/// horizontal slider is something SwiftUI ships, and reimplementing one bought nothing but the
/// chance to get gesture handling wrong. This control is the case where there is no such option:
/// SwiftUI has **no vertical `Slider`**, and the obvious substitute of rotating one does not fit
/// either, because `Slider`'s thumb alone is about 28pt across. The thing this draws is a 4pt-wide
/// strip down the side of a 1×1 tile. There is nothing native that renders as that, so the strip is
/// drawn and dragged by hand.
///
/// The *contract* is still deliberately identical to the light modal's brightness slider, so the two
/// cannot drift:
///
/// - a local `dragPercent` holds the preview and is the only thing that moves during a drag;
/// - the command is sent **once, on release**, never per frame (a WebSocket call per pixel of
///   travel is not a kind thing to do to someone's Home Assistant);
/// - `.accessibilityAdjustableAction` performs the same commit, so the control is operable without
///   the gesture at all.
///
/// The track fills from the bottom, matching the static level bars it replaced — 0 at the bottom,
/// 100 at the top, so "more" is "up" as it is on any physical dimmer.
///
/// ## Why the gesture is on the pip and not on the track
///
/// A tile is already covered by gestures that matter more: a tap that toggles or opens the modal,
/// and a long press. A track-wide, tap-to-set slider inside one would mean a stray tap silently
/// changing the brightness of a light in another room — which is why the tiles carried *static*
/// readouts until now. So the drag target is the pip alone, and the value is driven by the
/// **translation of the drag**, not by the absolute position of the finger.
///
/// That combination is what makes a tap safe by construction rather than by a threshold: a touch
/// that lands on the pip and doesn't travel produces a translation of zero, and zero translation is
/// zero change. There is no minimum-distance heuristic to tune and no jump-to-finger to suppress —
/// the value simply cannot move unless the finger does. Dragging is also unbounded by the track's
/// length, so the user can carry on past either end to pin 0 or 100 rather than having to release
/// precisely on a 60pt strip.
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
/// anywhere else on the tile does.
struct PipSlider: View {
    /// The live value, 0…100, from the entity. Ignored while a drag is in flight.
    let percent: Int
    let accent: Color
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
    /// The pip's invisible touch target — square, and 24pt because that is Apple's minimum
    /// comfortable target. It is six times the drawn track's width, which is exactly why it has to
    /// be an overlay; see `body`.
    private let hitSize: CGFloat = 24
    /// Below this much travel a touch is a tap, not a drag. It only ever chooses between `onTap`
    /// and `onCommit` — the *value* is translation-driven either way, so this threshold can never
    /// be the reason a tap does or doesn't change something.
    private let tapSlop: CGFloat = 3
    /// Names the stationary track so the drag can be measured against something that doesn't move.
    /// See `drag(travel:)` for why the default `.local` space cannot be used here.
    private let trackSpace = "PipSliderTrack"

    private var displayed: Double { dragPercent ?? Double(max(0, min(100, percent))) }
    private var fraction: CGFloat { CGFloat(displayed) / 100 }

    var body: some View {
        GeometryReader { geo in
            let travel = max(0, geo.size.height - pip)
            let filled = max(pip / 2, fraction * travel + pip / 2)
            ZStack(alignment: .bottom) {
                bar(HavenColor.levelTrack, along: nil)
                bar(accent, along: filled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // **The pip is an overlay, not a stack child, and that is the whole trick.** An overlay
            // is sized by what it sits on and may overflow it without ever being consulted about
            // that view's size — so a 10pt pip and a 24pt grab region cost a 4pt track exactly
            // nothing in layout.
            //
            // Getting this wrong is what made the light and shade bars render as fat blobs a third
            // of a tile wide: as a `ZStack` child, the pip's touch frame was the widest thing in
            // the stack, the track capsules had no width of their own, and so they stretched to
            // fill it. Hence `bar(_:along:)` below pinning `thickness` explicitly — the drawn
            // track's width is now stated, not inherited from whatever else is in the stack.
            .overlay(alignment: .bottom) {
                pipHandle(travel: travel)
            }
            // The fixed reference the drag is measured against. It sits on the track — which never
            // moves — rather than on the pip, which does.
            .coordinateSpace(.named(trackSpace))
        }
        // Exactly the footprint of the static bar this replaces: a 4pt-wide column. No tile's
        // layout width changes because this control is in it.
        .frame(width: thickness)
        // Not `.accessibilityHidden` — these were static readouts the tile's own label already
        // described, and that was right for a readout. A *control* a VoiceOver user cannot reach or
        // change is worse than an unlabelled one.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(displayed.rounded()))%")
        .accessibilityAdjustableAction { direction in
            let next = direction == .increment ? min(100, displayed + 5) : max(Double(minimum), displayed - 5)
            commit(next)
        }
    }

    /// One of the two capsules. `along` is the height — `nil` for the full-length track, a measured
    /// value for the fill. **The width is always `thickness`**, stated rather than inherited: a
    /// capsule left flexible across the axis takes its width from whatever else shares its stack,
    /// which is exactly how the bars ended up as wide as the pip's touch target.
    private func bar(_ color: Color, along: CGFloat?) -> some View {
        Capsule().fill(color).frame(width: thickness, height: along)
    }

    /// The pip, plus its invisible grab region.
    ///
    /// The region is `Color.clear` in an overlay on the pip for the same reason the pip is an
    /// overlay on the track: it must be generous to the finger and invisible to the layout. A
    /// touch target the size of the drawn pip would be 10pt, which is not a target; a drawn pip the
    /// size of the target would be the blob this replaced.
    private func pipHandle(travel: CGFloat) -> some View {
        Circle()
            .fill(accent)
            .frame(width: pip, height: pip)
            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
            .overlay {
                Color.clear
                    .frame(width: hitSize, height: hitSize)
                    .contentShape(Rectangle())
                    .gesture(drag(travel: travel))
            }
            // No clamping needed: `travel` is `height - pip`, so the drawn pip stays inside the
            // track by construction at both ends.
            .offset(y: -fraction * travel)
    }

    private func drag(travel: CGFloat) -> some Gesture {
        // `minimumDistance: 0` so the pip responds the instant it is touched — the "tapped and
        // dragged on" feel — which is safe only because the value is translation-driven.
        //
        // **The coordinate space must be the stationary track, never the default `.local`.**
        // `.local` is local to the view the gesture is attached to, and that view is the pip —
        // which this very drag moves. That closes a feedback loop: the finger travels 10pt, the
        // value rises, the pip offsets 10pt to follow it, and in the pip's *new* local space the
        // finger is back where it started, so the translation collapses to zero and the value
        // snaps back — which moves the pip back under the finger, and round again. The control
        // oscillates instead of tracking, several times a second.
        //
        // Measured against the track, which does not move, `startLocation` and `location` are both
        // stable and the translation is simply how far the finger has gone. A short track makes the
        // defect violent rather than merely present — a 1×1 tile is only ~60pt tall, so the same
        // finger movement swings a large share of the range — which is why it is worth stating in
        // a comment that outlives whoever next edits this line.
        DragGesture(minimumDistance: 0, coordinateSpace: .named(trackSpace))
            .onChanged { value in
                let origin = dragOrigin ?? displayed
                if dragOrigin == nil { dragOrigin = origin }
                guard travel > 0 else { return }
                // Dragging *up* is a negative translation and more level, hence the negation.
                let delta = Double(-value.translation.height / travel) * 100
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
        // its optimistic state into `states` synchronously (`LightOptimistic`, `CoverOptimistic`),
        // so `percent` has already caught up by the time this line runs. Without that, clearing
        // here would be exactly the snap-back D spec §10b item 2 describes — which is why those
        // helpers are a prerequisite for this control rather than a nicety alongside it.
        dragPercent = nil
    }
}
