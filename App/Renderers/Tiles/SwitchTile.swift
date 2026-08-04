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
        // Lit by the *derived* state where there is one, so the wash and the glyph cannot
        // disagree: a garage whose limits say shut must not glow because its cover entity still
        // reports "open".
        GlassTile(active: store.deviceState(of: entityId).isActive ?? on,
                  accent: accent, unavailable: unavailable) {
            // The state in the middle, as for the other two-state tiles. `unavailable` is decided
            // by `TileState` rather than incidentally by `state == "on"` reading false for an
            // unreachable switch — which was right by accident rather than because anything chose
            // it.
            // **The device's own state where it has one.** A garage opener wired as a relay is a
            // switch in Home Assistant, and its own state says whether a contact closed rather than
            // where the door is — so a `garage_door` device reads its limit sensors instead. See
            // `CompositeState.derivedFace`.
            StateFace(state: store.deviceState(of: entityId).face
                      ?? TileState.switchOutlet(deviceClass: e?.deviceClass, isOn: on,
                                                unavailable: unavailable),
                      style: store.stateStyle(of: entityId),
                      name: name,
                      accent: accent,
                      // The derived state's own tint where there is one — see `DeviceState.isActive`.
                      active: store.deviceState(of: entityId).isActive ?? on,
                      unavailable: unavailable)
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
