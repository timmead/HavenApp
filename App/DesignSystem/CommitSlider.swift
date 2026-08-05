import SwiftUI

/// A horizontal level control that **previews locally and commits once, on release**.
///
/// This is the shape the light modal's brightness and colour temperature, the cover modal's
/// position, and both media players' volume were each written out by hand — the media tile's copy
/// carrying a comment promising it matched the media modal's "line for line ... so the two cannot
/// drift", which is a component's job written as a note to the next reader. This is that component;
/// `PipSlider` is the vertical, tile-sized case that has no stock equivalent.
///
/// The contract, in the order the pieces matter:
///
/// - `preview` holds the value under the finger and is the **only** thing that moves during a drag.
///   While it is non-nil the control ignores `value` entirely, so a state push arriving mid-drag
///   cannot shift the thumb the user is holding.
/// - The command is sent **once, on release**, never per frame — a WebSocket call per pixel of
///   travel is not a kind thing to do to someone's Home Assistant.
/// - `accessibilityAdjustableAction` performs the same commit, so the control is fully operable
///   without the gesture.
///
/// ## Why `preview` is the caller's `@State`, not this view's
///
/// Each call site clears it on a different signal — the light modal on the light going *off*, the
/// cover modal on any change of open/closed, the media players never — and the light modal's kelvin
/// readout (`"…K"`) renders the previewed value in its own body, beside this control rather than
/// inside it. Owning the state here would flatten all three resets into one and put that readout out
/// of reach. "Local" here means local to the view, not local to this type.
///
/// ## Clearing the preview: on release always, after an adjustment sometimes
///
/// Release always clears. An adjustment clears **unless** `pinsPreviewAfterAdjusting`, and which of
/// those is right follows from one question: does the store method behind `onCommit` write its
/// optimistic value into `states` synchronously?
///
/// - **It does** (`setBrightness`, `setCoverPosition`, `setMediaVolume`) → clear. `value` has
///   already caught up by the time the commit returns, so there is nothing to bridge. Clearing is
///   not merely allowed here, it is *required*: brightness used to pin, from back when
///   `setBrightness` was fire-and-forget and `value` would otherwise still read the stale pre-swipe
///   number with each further swipe re-deriving from it. Now that `LightOptimistic.brightness`
///   lands synchronously, keeping the pin would be the new bug — a non-nil `preview` makes the
///   slider ignore every later state push, including the light being switched off. Clearing on
///   release rests on the same write; without it, release would show the snap-back D spec §10b
///   item 2 describes.
/// - **It does not** (`setColorTemp`, deliberately — see `HomeStore.setColorTemp`) → pin. Clearing
///   would leave `accessibilityValue`, and each next swipe's starting point, stuck on the stale
///   pre-swipe reading until Home Assistant's echo lands. Such a control still snaps back briefly
///   after a *drag*, since release clears unconditionally; that is long-standing behaviour and this
///   type does not change it.
struct CommitSlider: View {
    /// The live value from the store. Ignored whenever `preview` is non-nil.
    let value: Double
    /// The caller's drag state: non-nil only while dragging, or for as long as an adjustment is
    /// pinned. See the type's doc comment for why it lives out there.
    @Binding var preview: Double?
    let bounds: ClosedRange<Double>
    /// How far one accessibility adjustment moves the value. **This is not `Slider`'s `step:`** —
    /// every call site here has always used the continuous initialiser, and quantising the drag to
    /// this would be a behaviour change rather than a refactor.
    let adjustmentStep: Double
    let tint: Color
    let label: String
    /// See the doc comment. `false` — clear — is right wherever the commit is optimistic.
    var pinsPreviewAfterAdjusting: Bool = false
    /// Spoken as the slider's value. A closure rather than a string because the value shown is not
    /// always the number: a muted speaker says "Muted", a cover says "40% open", a light says
    /// "2700 Kelvin". Called with the displayed value — previewed if there is one, live otherwise.
    let valueDescription: (Double) -> String
    /// Called once on release, and once per accessibility adjustment. Never during a drag. Takes
    /// the raw value; rounding and the choice of store method stay with the caller.
    let onCommit: (Double) -> Void

    init(value: Double,
         preview: Binding<Double?>,
         in bounds: ClosedRange<Double>,
         adjustmentStep: Double,
         tint: Color,
         label: String,
         pinsPreviewAfterAdjusting: Bool = false,
         valueDescription: @escaping (Double) -> String,
         onCommit: @escaping (Double) -> Void) {
        self.value = value
        self._preview = preview
        self.bounds = bounds
        self.adjustmentStep = adjustmentStep
        self.tint = tint
        self.label = label
        self.pinsPreviewAfterAdjusting = pinsPreviewAfterAdjusting
        self.valueDescription = valueDescription
        self.onCommit = onCommit
    }

    private var displayed: Double { preview ?? value }

    // A bare `Slider` with modifiers on it, and no container around it. The media tile frames this
    // control to 24pt and argues at length there that the height is load-bearing against
    // `GlassTile`'s 66pt floor; a transparent single-child view passes that through, a stack or a
    // `Group` need not.
    var body: some View {
        Slider(value: Binding(get: { displayed }, set: { preview = $0 }),
               in: bounds,
               onEditingChanged: { editing in
                   if !editing, let v = preview {
                       onCommit(v)
                       preview = nil
                   }
               })
        .tint(tint)
        .accessibilityLabel(label)
        .accessibilityValue(valueDescription(displayed))
        .accessibilityAdjustableAction { direction in
            let next = direction == .increment
                ? min(bounds.upperBound, displayed + adjustmentStep)
                : max(bounds.lowerBound, displayed - adjustmentStep)
            onCommit(next)
            preview = pinsPreviewAfterAdjusting ? next : nil
        }
    }
}
