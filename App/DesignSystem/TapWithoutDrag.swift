import SwiftUI

/// A row that acts on a tap, and **not** on the lift at the end of a scroll.
///
/// A `Button` inside a `ScrollView` is normally cancelled when the scroll wins the gesture. In a
/// sheet it is not reliably: `presentationDetents` adds a drag of its own competing for the same
/// touch, and during the handoff the button can still receive its touch-up. The symptom is precise
/// and maddening — flick the list to scroll, lift your finger, and whatever happened to be under it
/// is selected.
///
/// **The fix is the gesture, not extra logic around it.** `TapGesture` requires the touch to stay
/// put: a finger that travels cancels it, which is exactly the rule wanted here. A `Button`'s press
/// gesture has no such requirement — it fires on touch-up inside its bounds however far the finger
/// wandered first — and that difference is the whole bug.
///
/// The first attempt observed a `DragGesture(minimumDistance: 0)` alongside the button and declined
/// to act when the finger had moved. It worked and it was much worse: a zero-distance drag gesture
/// takes the touch from the scroll view even as a `simultaneousGesture`, so the list stopped
/// scrolling entirely. Reaching for gesture machinery to fix a gesture was the mistake; the smaller
/// answer was to use the gesture that already means "tap".
struct TapWithoutDrag: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

extension View {
    /// Calls `action` on a tap, ignoring the lift at the end of a scroll. See `TapWithoutDrag`.
    func tapWithoutDrag(perform action: @escaping () -> Void) -> some View {
        modifier(TapWithoutDrag(action: action))
    }
}
