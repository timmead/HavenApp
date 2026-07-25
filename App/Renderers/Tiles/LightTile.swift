import SwiftUI
import HavenCore
struct LightTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId)
        let s = e.map(LightState.init)
        let on = s?.isOn ?? false
        let accent = HavenColor.domain(.light)
        GlassTile(active: on, accent: accent) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Image(systemName: IconMap.symbol(domain: .light, deviceClass: nil))
                        .font(.system(size: 20)).foregroundStyle(on ? accent : .secondary).symbolRenderingMode(.hierarchical)
                    Spacer(minLength: 2)
                    Text(TileName.of(entityId, e)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(on ? .primary : .secondary)
                }
                if on, let pct = s?.brightnessPercent { Spacer(minLength: 6); LevelBar(percent: pct, color: accent).padding(.vertical, 2) }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.toggle(entityId) }
        .onLongPressGesture(minimumDuration: 0.35) { store.presented = entityId }
    }
}
