import SwiftUI
import HavenCore
struct LockTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId); let s = e.map(LockState.init)
        let locked = s?.isLocked ?? false; let jammed = s?.isJammed ?? false
        let unavailable = e?.isUnavailable ?? false
        let accent = jammed ? HavenColor.warning : (locked ? HavenColor.domain(.lock) : HavenColor.warning)
        // Neither half of `symbol` nor `accent` is safe to trust once the lock is unreachable:
        // `isLocked`/`isJammed` both read `false` for an `unavailable` state string exactly as
        // they would for a genuinely unlocked one, so left alone this renders a confident orange
        // *open* padlock for a door we know nothing about — worse than the calm state this task
        // exists to add. `unavailable` overrides both to the neutral domain glyph in `.secondary`,
        // which asserts neither locked nor unlocked.
        let symbol = unavailable ? IconMap.symbol(domain: .lock, deviceClass: e?.deviceClass)
            : (jammed ? "lock.trianglebadge.exclamationmark" : (locked ? "lock.fill" : "lock.open.fill"))
        GlassTile(active: false, accent: accent, unavailable: unavailable) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(unavailable ? .secondary : accent).symbolRenderingMode(.hierarchical)
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
