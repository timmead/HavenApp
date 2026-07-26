import SwiftUI
import HavenCore
struct CoverTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId); let s = e.map(CoverState.init)
        let open = s?.isOpen ?? false; let accent = HavenColor.domain(.cover)
        GlassTile(active: open, accent: accent) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Image(systemName: IconMap.symbol(domain: .cover, deviceClass: e?.deviceClass)).font(.system(size: 20)).foregroundStyle(open ? accent : .secondary).symbolRenderingMode(.hierarchical)
                    Spacer(minLength: 2); Text(TileName.of(entityId, e)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).foregroundStyle(open ? .primary : .secondary)
                }
                if let pos = s?.positionPercent { Spacer(minLength: 6); LevelBar(percent: pos, color: accent).padding(.vertical, 2) }
            }
        }
        .contentShape(Rectangle()).onTapGesture { store.openCloseCover(entityId) }.onLongPressGesture(minimumDuration: 0.35) { store.presented = entityId }
    }
}
