import SwiftUI
import HavenCore
struct SwitchTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId)
        let on = (e?.state == "on")
        let accent = HavenColor.domain(.switchOutlet)
        let name = TileName.of(entityId, e)
        let unavailable = e?.isUnavailable ?? false
        GlassTile(active: on, accent: accent, unavailable: unavailable) {
            // Both emphases are stated as what the tile wants *when reachable*; `TileLabel`
            // applies the unavailable rule. `on` already reads `false` for an `unavailable` state
            // string, so these would resolve to `.secondary` there anyway — but incidentally, via
            // the `state == "on"` check, rather than because anything decided it.
            TileLabel(symbol: IconMap.symbol(domain: .switchOutlet, deviceClass: nil),
                      name: name,
                      icon: on ? .accent : .secondary,
                      title: on ? .primary : .secondary,
                      accent: accent, unavailable: unavailable)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.toggle(entityId) }
        .onLongPressGesture(minimumDuration: 0.35) { store.presented = entityId }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AccessibilitySummary.switchOutlet(name, isOn: on))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open controls") { store.presented = entityId }
    }
}
