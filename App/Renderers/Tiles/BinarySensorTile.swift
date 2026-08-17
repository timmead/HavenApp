import SwiftUI
import HavenCore
struct BinarySensorTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation
    /// Which surface this tile is on — set by `ConfigurableTile`, and what a tap in
    /// configuration mode removes it from.
    @Environment(\.havenSurface) private var surface
    var body: some View {
        let e = store.state(entityId); let s = e.map(BinarySensorState.init)
        let active = s?.isActive ?? false
        let accent = HavenColor.warning
        let unavailable = e?.isUnavailable ?? false
        GlassTile(active: active, accent: accent, unavailable: unavailable) {
            // **The state is the tile.** A door sensor has no control and no reading — whether the
            // door is open is the only thing it has to say — so it says it in the middle, large,
            // rather than in a 20pt glyph in a corner that made every binary tile look alike until
            // you read the tint. The glyph now differs between states; `TileState` owns that table
            // and the unreachable rule with it.
            StateFace(state: TileState.binarySensor(deviceClass: e?.deviceClass,
                                                    isActive: active, unavailable: unavailable),
                      style: store.stateStyle(of: entityId),
                      name: store.displayName(of: entityId),
                      accent: accent, active: active, unavailable: unavailable,
                      nameHidden: store.labelHidden(of: entityId))
        }
        .contentShape(Rectangle()).onTapGesture { navigation.open(entityId, on: surface) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.map { AccessibilitySummary.binarySensor(store.displayName(of: entityId), $0) } ?? store.displayName(of: entityId))
        .accessibilityAddTraits(.isButton)
    }
}
