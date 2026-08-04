import SwiftUI

/// A row that acts on a tap, and **not** on the lift at the end of a scroll.
///
/// A `Button` inside a `ScrollView` is normally cancelled when the scroll wins the gesture. In a
/// sheet it is not reliably: `presentationDetents` adds a drag of its own competing for the same
/// touch, and during the handoff between the two the button can still receive its touch-up. The
/// symptom is precise and maddening — flick the list to scroll, lift your finger, and whatever
/// happened to be under it is selected.
///
/// **This suppresses a press that moved; it does not implement scrolling.** That distinction is the
/// whole reason it is written this way. This codebase has twice been bitten by hand-rolled pan logic
/// — `RearrangeableTile` records both — so the scroll view keeps the pan, keeps its momentum, keeps
/// its rubber-banding, and this only declines to call the action when the finger travelled far
/// enough that the gesture was plainly not a tap.
///
/// The threshold is 10 points, which is roughly what UIKit uses to break a tap into a pan. Below it
/// a finger is holding still; above it, it is going somewhere.
struct TapWithoutDrag: ViewModifier {
    let action: () -> Void
    @State private var travelled = false

    private static let threshold: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            // Simultaneous, so the scroll view still sees every part of the gesture — this observes
            // the drag rather than consuming it.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let distance = max(abs(value.translation.width),
                                           abs(value.translation.height))
                        if distance > Self.threshold { travelled = true }
                    }
                    .onEnded { _ in
                        // Reset on the next turn, after `onTapGesture` below has had its chance to
                        // read it. Resetting here directly would clear the flag before the tap is
                        // evaluated, which is the bug this exists to prevent.
                        let moved = travelled
                        Task { @MainActor in travelled = false }
                        if !moved { action() }
                    }
            )
    }
}

extension View {
    /// Calls `action` on a tap, ignoring the lift at the end of a scroll. See `TapWithoutDrag`.
    func tapWithoutDrag(perform action: @escaping () -> Void) -> some View {
        modifier(TapWithoutDrag(action: action))
    }
}
