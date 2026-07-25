import SwiftUI
import HavenCore
struct SwitchTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId)
        let on = (e?.state == "on")
        let accent = HavenColor.domain(.switchOutlet)
        GlassTile(active: on, accent: accent) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: IconMap.symbol(domain: .switchOutlet, deviceClass: nil)).font(.system(size: 20)).foregroundStyle(on ? accent : .secondary).symbolRenderingMode(.hierarchical)
                Spacer(minLength: 2)
                Text(TileName.of(entityId, e)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).foregroundStyle(on ? .primary : .secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.toggle(entityId) }
        .onLongPressGesture(minimumDuration: 0.35) { store.presented = entityId }
    }
}
