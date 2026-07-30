import SwiftUI
import HavenCore
struct SceneTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation
    /// Which surface this tile is on — set by `ConfigurableTile`, and what a tap in
    /// configuration mode removes it from.
    @Environment(\.havenSurface) private var surface
    var body: some View {
        let e = store.state(entityId); let accent = HavenColor.domain(.scene)
        let unavailable = e?.isUnavailable ?? false
        GlassTile(active: false, accent: accent, unavailable: unavailable) {
            // Always tinted `accent` by design, same as `ClimateTile` — a scene has no on/off to
            // gate it on. That is exactly the case that used to need its unavailable guard written
            // by hand, having no state check to inherit one from.
            TileLabel(symbol: IconMap.symbol(domain: Domain.of(entityId), deviceClass: nil),
                      name: store.displayName(of: entityId),
                      icon: .accent,
                      accent: accent, unavailable: unavailable)
        }
        .contentShape(Rectangle()).onTapGesture { store.run(entityId) }.onLongPressGesture(minimumDuration: 0.35) { navigation.open(entityId, on: surface) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AccessibilitySummary.scene(store.displayName(of: entityId)))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open controls") { navigation.open(entityId, on: surface) }
    }
}
