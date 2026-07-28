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
            VStack(alignment: .leading, spacing: 5) {
                // `on` already reads `false` for an `unavailable` state string, same as for a
                // genuinely off switch, so this guard is currently redundant with that — but
                // stated explicitly rather than left to depend on the `state == "on"` check above
                // never changing.
                Image(systemName: IconMap.symbol(domain: .switchOutlet, deviceClass: nil)).font(.system(size: 20)).foregroundStyle(unavailable ? .secondary : (on ? accent : .secondary)).symbolRenderingMode(.hierarchical)
                Spacer(minLength: 2)
                // Same guard as the icon above, and for the same reason: `on` already reads
                // `false` for an `unavailable` state string, so this is currently redundant with
                // that — but stated explicitly rather than left to depend on it.
                Text(name).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).foregroundStyle(unavailable ? .secondary : (on ? .primary : .secondary))
            }
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
