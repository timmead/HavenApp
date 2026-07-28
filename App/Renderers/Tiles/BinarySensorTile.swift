import SwiftUI
import HavenCore
struct BinarySensorTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId); let s = e.map(BinarySensorState.init)
        let active = s?.isActive ?? false
        let accent = HavenColor.warning
        let unavailable = e?.isUnavailable ?? false
        GlassTile(active: active, accent: accent, unavailable: unavailable) {
            // The symbol is the neutral device-class glyph in every state, not an active/clear
            // variant, so it needs no unavailable-specific choice of its own — only the tint,
            // which `TileLabel` resolves. The name stays `.primary` when reachable: unlike a light
            // or a switch, a *clear* door sensor is not "off", it is simply reporting.
            TileLabel(symbol: IconMap.symbol(domain: .binarySensor, deviceClass: e?.deviceClass),
                      name: TileName.of(entityId, e),
                      icon: active ? .accent : .secondary,
                      accent: accent, unavailable: unavailable)
        }
        .contentShape(Rectangle()).onTapGesture { store.presented = entityId }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.map { AccessibilitySummary.binarySensor(TileName.of(entityId, e), $0) } ?? TileName.of(entityId, e))
        .accessibilityAddTraits(.isButton)
    }
}
