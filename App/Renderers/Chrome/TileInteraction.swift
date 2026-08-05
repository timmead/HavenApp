import SwiftUI

/// The gesture and accessibility contract every two-state tile shares: tap to act, long-press to
/// open the controls, one combined VoiceOver element.
///
/// Written out identically at the foot of `SwitchTile`, `LightTile`, `LockTile` and `CoverTile` —
/// seven modifiers, four times, differing only in which command the tap sends and which
/// `AccessibilitySummary` builds the label. Two of the four had been squeezed onto a single line,
/// which is what copy-paste looks like once it has been through a formatter.
///
/// Lives in `Renderers/Chrome/` rather than `DesignSystem/` because it reads `Navigation` out of
/// the environment — see `ConfigurableTile` for the rule.
///
/// **The gestures are unchanged, deliberately.** `.onTapGesture` and not `tapWithoutDrag`: these
/// tiles have always used the plain gesture, and the scroll-lift fix `TapWithoutDrag` exists for
/// was made in the *configuration sheets*, where a stray tap at the end of a scroll adds a tile or
/// rebinds a role rather than toggling a light that is already in front of you. Adopting it here
/// would be a behaviour change wearing a refactor's clothes. Configuration mode still disables all
/// of this from above, through `ConfigurableTile`'s `allowsHitTesting`.
struct TileInteraction: ViewModifier {
    let entityId: String
    /// Built by the caller from `AccessibilitySummary`, because each domain's summary takes its own
    /// typed state — assembling it here would mean this one type knowing all of them.
    let accessibilityLabel: String
    /// What a tap sends. The one behaviour every tile answers differently.
    let onTap: () -> Void

    @Environment(Navigation.self) private var navigation
    @Environment(\.havenSurface) private var surface

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onLongPressGesture(minimumDuration: 0.35) { navigation.open(entityId, on: surface) }
            // One combined element per tile, not five fragments — a VoiceOver user hears
            // "Kitchen light, on, 60% brightness" once, not the icon/name/level bar separately.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Open controls") { navigation.open(entityId, on: surface) }
    }
}

extension View {
    /// Tap to act, long-press for the controls, one combined VoiceOver element.
    /// See `TileInteraction`.
    func tileInteraction(_ entityId: String,
                         label: String,
                         onTap: @escaping () -> Void) -> some View {
        modifier(TileInteraction(entityId: entityId, accessibilityLabel: label, onTap: onTap))
    }
}
