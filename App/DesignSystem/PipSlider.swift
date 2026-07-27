import SwiftUI

/// A compact draggable level control for a **tile**: a hairline track with a small pip on it.
///
/// It exists because the tiles cannot use the full-size `Slider` the modals do — that control is
/// taller than a tile's whole volume row — but the *contract* is deliberately identical to the
/// light modal's brightness slider, so the two cannot drift:
///
/// - a local `dragPercent` holds the preview and is the only thing that moves during a drag;
/// - the command is sent **once, on release**, never per frame (a WebSocket call per pixel of
///   travel is not a kind thing to do to someone's Home Assistant);
/// - `.accessibilityAdjustableAction` performs the same commit, so the control is operable without
///   the gesture at all.
///
/// ## Why the gesture is on the pip and not on the track
///
/// A tile is already covered by gestures that matter more: a tap that opens the modal and a long
/// press. A track-wide, tap-to-set slider inside one would mean a stray tap silently changing the
/// volume of a speaker in another room — which is exactly why the tiles carried a *static* readout
/// until now. So the drag target is the pip alone, and the value is driven by the **translation of
/// the drag**, not by the absolute position of the finger.
///
/// That combination is what makes a tap safe by construction rather than by a threshold: a touch
/// that lands on the pip and doesn't travel produces a translation of zero, and zero translation is
/// zero change. There is no minimum-distance heuristic to tune and no jump-to-finger to suppress —
/// the value simply cannot move unless the finger does. Dragging is also unbounded by the track's
/// width, so the user can carry on past either end to pin it at 0 or 100 rather than having to
/// release precisely on a 100-point-wide strip.
struct PipSlider: View {
    /// The live value, 0…100, from the entity. Ignored while a drag is in flight.
    let percent: Int
    let accent: Color
    /// Draws the control in its inactive treatment and adds "muted" to the spoken value. The pip
    /// still sits at the **real** level rather than at zero — see `HavenColor` usage below.
    var isMuted: Bool = false
    let label: String
    /// Called on release and on an accessibility adjustment. Never called during a drag.
    let onCommit: (Int) -> Void

    /// Non-nil only while dragging (or for the instant an adjustable action takes), exactly as
    /// `LightModal.dragPercent` is.
    @State private var dragPercent: Double?
    /// The value the current drag started from. Translation is applied to this rather than to the
    /// live value, so a state push arriving mid-drag can't shift the thing under the finger.
    @State private var dragOrigin: Double?

    private let pip: CGFloat = 11
    private let trackHeight: CGFloat = 4
    /// The pip's touch target, comfortably larger than the pip itself. 28×24 keeps it reachable
    /// without spilling far enough to swallow taps meant for the controls beside it.
    private let hitWidth: CGFloat = 28
    private let hitHeight: CGFloat = 24

    private var displayed: Double { dragPercent ?? Double(max(0, min(100, percent))) }
    private var fraction: CGFloat { CGFloat(displayed) / 100 }
    /// Dimmed while muted: the level is still true, it just isn't doing anything right now.
    private var fill: Color { isMuted ? HavenColor.warning.opacity(0.55) : accent }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let travel = max(0, width - pip)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(HavenColor.levelTrack)
                    .frame(height: trackHeight)
                Capsule()
                    .fill(fill)
                    .frame(width: max(pip / 2, fraction * travel + pip / 2), height: trackHeight)
                Circle()
                    .fill(fill)
                    .frame(width: pip, height: pip)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    .frame(width: hitWidth, height: hitHeight)
                    .contentShape(Rectangle())
                    // Clamped to the control's own bounds. The touch target is wider than the pip,
                    // so at 0% an unclamped offset would put its left edge ~8pt outside the track —
                    // far enough to eat the edge of the mute button sitting 7pt away, which is
                    // precisely the kind of quiet theft of someone else's tap target that makes a
                    // control feel unreliable without ever looking wrong.
                    .offset(x: min(max(0, fraction * travel - (hitWidth - pip) / 2),
                                   max(0, width - hitWidth)))
                    .gesture(drag(travel: travel))
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: hitHeight)
        // No longer `.accessibilityHidden` — it was, while this was a static readout the tile's own
        // label already described. A control a VoiceOver user cannot reach or change is worse than
        // an unlabelled one, so it is now a first-class adjustable element.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spokenValue)
        .accessibilityAdjustableAction { direction in
            let next = direction == .increment ? min(100, displayed + 5) : max(0, displayed - 5)
            commit(next)
        }
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
                let delta = Double(value.translation.width / travel) * 100
                dragPercent = min(100, max(0, origin + delta))
            }
            .onEnded { _ in
                dragOrigin = nil
                guard let value = dragPercent else { return }
                commit(value)
            }
    }

    private func commit(_ value: Double) {
        onCommit(Int(value.rounded()))
        // Cleared immediately, and that is safe here for the reason `MediaPlayerModal`'s volume
        // slider already records: the volume command writes its optimistic `volume_level` into
        // `states` synchronously, so `percent` has already caught up by the time this line runs.
        // (The light modal's sliders deliberately do the opposite and pin the preview, because
        // `setBrightness`/`setColorTemp` are fire-and-forget with no optimistic write to catch up.)
        dragPercent = nil
    }
}
