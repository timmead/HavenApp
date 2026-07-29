import SwiftUI

/// Makes a tile a **configuration target** while the dashboard is being edited, and inert
/// underneath.
///
/// The alternative was routing every gesture through the mode by hand — the tiles hold roughly
/// twenty of them between taps, long presses, transport buttons, steppers and volume sliders — and
/// each one would have been a place to forget. The failure that invites is specific and bad: a tap
/// meant to open a light's configuration turns the light on instead, or a stray drag changes the
/// heating while the user is renaming the thermostat.
///
/// So the whole tile stops hit-testing and a transparent layer over it takes the tap. One rule, one
/// place, and a tile added later inherits it by being built where the others are built.
///
/// **Appearance is deliberately untouched** — no dimming, no wobble. `.disabled()` would have been
/// the obvious way to make the controls inert, and it fades every button on the tile, which reads
/// as "this device is unavailable" — a state this app spends a great deal of care distinguishing
/// from every other. The mode is legible from the banner and the Done button, not from tiles
/// pretending to be broken.
struct ConfigurableTile: ViewModifier {
    let entityId: String
    @Environment(Navigation.self) private var navigation

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!navigation.isConfiguring)
            .overlay {
                if navigation.isConfiguring {
                    // `.contentShape` because an empty `Rectangle().fill(.clear)` is not hit-testable
                    // on its own — the tap would fall straight through to the inert tile below and
                    // nothing would happen at all.
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { navigation.open(entityId) }
                        .accessibilityElement()
                        .accessibilityLabel("Configure")
                        .accessibilityAddTraits(.isButton)
                }
            }
    }
}

extension View {
    /// See `ConfigurableTile`. Applied where tiles are *constructed* — `DeviceTileView` for the
    /// grid, and the two surfaces that build wide media and camera tiles directly — rather than
    /// inside each renderer, so there is one list of places to keep right.
    func configurable(entityId: String) -> some View {
        modifier(ConfigurableTile(entityId: entityId))
    }
}
