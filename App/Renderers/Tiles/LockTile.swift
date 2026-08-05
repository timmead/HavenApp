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
        GlassTile(active: false, accent: accent, unavailable: unavailable) {
            // **The glyph rule this file used to own now lives in `TileState.lock`, with tests.**
            // It is the same rule and it mattered enough to keep verbatim: `isLocked` and `isJammed`
            // both read false for an unreachable lock exactly as they would for a genuinely unlocked
            // one, so the domain glyph would state confidently that a door is open when Haven knows
            // nothing about it — and `IconMap.symbol(domain: .lock, ...)` resolves to `lock.fill`,
            // which would swap that false claim for a worse one in a security context.
            //
            // Moving it out was worth doing because two other tiles needed the same discipline and
            // were about to grow their own copies of it — and because a rule this consequential
            // belongs somewhere a test can reach, which inside a view it was not.
            StateFace(state: TileState.lock(isLocked: locked, isJammed: jammed,
                                            unavailable: unavailable),
                      style: store.stateStyle(of: entityId),
                      name: store.displayName(of: entityId),
                      accent: accent, active: true, unavailable: unavailable)
        }
        .tileInteraction(entityId,
                         label: s.map { AccessibilitySummary.lock(store.displayName(of: entityId), $0) }
                             ?? store.displayName(of: entityId)) {
            store.toggleLock(entityId)
        }
    }
}
