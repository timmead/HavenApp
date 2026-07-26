import SwiftUI
import HavenCore
struct BinarySensorTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId); let s = e.map(BinarySensorState.init)
        let active = s?.isActive ?? false
        let accent = HavenColor.warning
        GlassTile(active: active, accent: accent) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: IconMap.symbol(domain: .binarySensor, deviceClass: e?.deviceClass)).font(.system(size: 20)).foregroundStyle(active ? accent : .secondary).symbolRenderingMode(.hierarchical)
                Spacer(minLength: 2); Text(TileName.of(entityId, e)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            }
        }
        .contentShape(Rectangle()).onTapGesture { store.presented = entityId }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.map { AccessibilitySummary.binarySensor(TileName.of(entityId, e), $0) } ?? TileName.of(entityId, e))
        .accessibilityAddTraits(.isButton)
    }
}
