import SwiftUI
import HavenCore
struct LockTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId); let s = e.map(LockState.init)
        let locked = s?.isLocked ?? false
        let accent = locked ? HavenColor.domain(.lock) : Color(red: 0.85, green: 0.45, blue: 0.1)
        GlassTile(active: false, accent: accent) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: locked ? "lock.fill" : "lock.open.fill").font(.system(size: 20)).foregroundStyle(accent).symbolRenderingMode(.hierarchical)
                Spacer(minLength: 2); Text(TileName.of(entityId, e)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            }
        }
        .contentShape(Rectangle()).onTapGesture { store.toggleLock(entityId) }.onLongPressGesture(minimumDuration: 0.35) { store.presented = entityId }
    }
}
