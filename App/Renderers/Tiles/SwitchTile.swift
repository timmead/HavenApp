import SwiftUI
import HavenCore
struct SwitchTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation
    /// Which surface this tile is on — set by `ConfigurableTile`, and what a tap in
    /// configuration mode removes it from.
    @Environment(\.havenSurface) private var surface
    var body: some View {
        let e = store.state(entityId)
        let on = (e?.state == "on")
        let accent = HavenColor.domain(.switchOutlet)
        let name = store.displayName(of: entityId)
        let unavailable = e?.isUnavailable ?? false
        GlassTile(active: on, accent: accent, unavailable: unavailable) {
            // The state in the middle, as for the other two-state tiles. `unavailable` is decided
            // by `TileState` rather than incidentally by `state == "on"` reading false for an
            // unreachable switch — which was right by accident rather than because anything chose
            // it.
            StateFace(state: TileState.switchOutlet(deviceClass: e?.deviceClass, isOn: on,
                                                    unavailable: unavailable),
                      style: store.stateStyle(of: entityId),
                      name: name,
                      accent: accent, active: on, unavailable: unavailable)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.toggle(entityId) }
        .onLongPressGesture(minimumDuration: 0.35) { navigation.open(entityId, on: surface) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AccessibilitySummary.switchOutlet(name, isOn: on))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open controls") { navigation.open(entityId, on: surface) }
    }
}
