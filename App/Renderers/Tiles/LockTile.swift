import SwiftUI
import HavenCore
struct LockTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId); let s = e.map(LockState.init)
        let locked = s?.isLocked ?? false; let jammed = s?.isJammed ?? false
        let accent = jammed ? HavenColor.warning : (locked ? HavenColor.domain(.lock) : HavenColor.warning)
        let symbol = jammed ? "lock.trianglebadge.exclamationmark" : (locked ? "lock.fill" : "lock.open.fill")
        let unavailable = store.state(entityId)?.isUnavailable ?? false
        GlassTile(active: false, accent: accent, unavailable: unavailable) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(accent).symbolRenderingMode(.hierarchical)
                Spacer(minLength: 2); Text(TileName.of(entityId, e)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            }
        }
        .contentShape(Rectangle()).onTapGesture { store.toggleLock(entityId) }.onLongPressGesture(minimumDuration: 0.35) { store.presented = entityId }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.map { AccessibilitySummary.lock(TileName.of(entityId, e), $0) } ?? TileName.of(entityId, e))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open controls") { store.presented = entityId }
    }
}
