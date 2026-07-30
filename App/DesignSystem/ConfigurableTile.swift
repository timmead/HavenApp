import SwiftUI
import HavenCore

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
/// **In configuration mode a tile shows what it *is*, not what it is doing.** Its live state is
/// covered by a placeholder: a solid 2pt border matching the `+` slot's dashed one, the device's
/// icon, and its name. Nothing else — a room being edited is a room you are arranging, and eleven
/// tiles reporting brightness, temperature and playback position while you rearrange them is a lot
/// of motion in a screen that should feel still.
///
/// This is deliberately *not* `.disabled()`-style fading, which was the first thing tried: dimming
/// reads as "this device is unavailable", a state this app spends real care distinguishing from
/// every other. A placeholder gives configuration mode its own vocabulary instead of borrowing the
/// one that already means something else.
///
/// **An overlay, not a substitution**, and that is what keeps the grid still. A camera tile is 2×2
/// and a wide media tile 4×2; swapping in a placeholder view would make every such tile collapse to
/// whatever height the placeholder asked for. Overlaid, the real tile still lays out — so every
/// height, span and grid position is exactly what it is outside the mode — and only its *drawing*
/// is replaced.
struct ConfigurableTile: ViewModifier {
    let entityId: String
    /// Which surface this tile is on, so its configuration sheet knows what "remove" removes it
    /// from. **No default**: the two surfaces are the whole point of tile membership, and a default
    /// would let a new call site silently claim to be the dashboard.
    let surface: HavenSurface
    @Environment(Navigation.self) private var navigation
    @Environment(HomeStore.self) private var store

    func body(content: Content) -> some View {
        content
            // Published so the tile's *own* gestures — a long press, an accessibility action — can
            // route to the same surface without eleven renderers each taking a parameter for it.
            // See `EnvironmentValues.havenSurface`.
            .environment(\.havenSurface, surface)
            .allowsHitTesting(!navigation.isConfiguring)
            .overlay {
                if navigation.isConfiguring {
                    TilePlaceholder(entityId: entityId)
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .onTapGesture { navigation.open(entityId, on: surface) }
                        .accessibilityElement()
                        .accessibilityLabel("\(store.displayName(of: entityId)), configure")
                        .accessibilityAddTraits(.isButton)
                }
            }
    }
}

/// What a tile looks like while the dashboard is being arranged: what it is, not what it is doing.
///
/// Opaque, because it covers a live tile rather than replacing it — see `ConfigurableTile`. The
/// border is solid where the `+` slot's is dashed, at the same 1.5pt weight: one says "a tile is
/// here", the other "a tile could be".
private struct TilePlaceholder: View {
    let entityId: String
    @Environment(HomeStore.self) private var store

    var body: some View {
        let e = store.state(entityId)
        let accent = HavenColor.domain(Domain.of(entityId))
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.background)
            .overlay {
                VStack(alignment: .leading, spacing: 5) {
                    Image(systemName: IconMap.symbol(domain: Domain.of(entityId),
                                                     deviceClass: e?.deviceClass))
                        .font(.system(size: 20))
                        .foregroundStyle(accent)
                        .symbolRenderingMode(.hierarchical)
                    Spacer(minLength: 2)
                    Text(store.displayName(of: entityId))
                        .font(.system(size: 10.5, weight: .semibold))
                        // One line, as every real tile's name is: at a quarter of the screen a
                        // second line breaks mid-word ("Temperatur / e"), which reads as damage.
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(EdgeInsets(top: 10, leading: 10, bottom: 9, trailing: 14))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(accent.opacity(0.5), lineWidth: 1.5)
            }
    }
}

extension View {
    /// See `ConfigurableTile`. Applied where tiles are *constructed* — `DeviceTileView` for the
    /// grid, and the two surfaces that build wide media and camera tiles directly — rather than
    /// inside each renderer, so there is one list of places to keep right.
    func configurable(entityId: String, on surface: HavenSurface) -> some View {
        modifier(ConfigurableTile(entityId: entityId, surface: surface))
    }
}
