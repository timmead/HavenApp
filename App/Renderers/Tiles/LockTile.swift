import SwiftUI
import HavenCore
struct LockTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation
    var body: some View {
        let e = store.state(entityId); let s = e.map(LockState.init)
        let locked = s?.isLocked ?? false; let jammed = s?.isJammed ?? false
        let unavailable = e?.isUnavailable ?? false
        let accent = jammed ? HavenColor.warning : (locked ? HavenColor.domain(.lock) : HavenColor.warning)
        // `symbol` is not safe to trust once the lock is unreachable: `isLocked`/`isJammed` both
        // read `false` for an `unavailable` state string exactly as they would for a genuinely
        // unlocked one, so left alone this renders a confident orange *open* padlock for a door we
        // know nothing about — worse than the calm state this task exists to add. `unavailable`
        // overrides it to `questionmark.circle`, the one glyph here that asserts neither locked nor
        // unlocked — **not** `IconMap.symbol(domain: .lock, ...)`, which resolves to `"lock.fill"`,
        // the *locked* variant, and would swap one false claim (open) for a worse one in a security
        // context (locked).
        //
        // `accent` needs no matching override: it never reaches the screen for an unreachable lock.
        // The icon's own `foregroundStyle` below is `unavailable ? .secondary : accent`, so
        // `unavailable` already wins there directly, and `GlassTile` below is passed `active:
        // false` unconditionally — its internal `lit = active && !unavailable` is therefore always
        // `false` for this tile, so the accent-tinted background/border/shadow it would otherwise
        // draw never appears regardless of `unavailable`. `accent` is computed and threaded through
        // for the locked/jammed cases where it *is* read (the icon's tint when not unavailable);
        // it stays untouched here rather than being given a redundant `unavailable` branch of its
        // own that would never be observed.
        let symbol = unavailable ? "questionmark.circle"
            : (jammed ? "lock.trianglebadge.exclamationmark" : (locked ? "lock.fill" : "lock.open.fill"))
        GlassTile(active: false, accent: accent, unavailable: unavailable) {
            // `symbol` is resolved above, by this file, and **must** stay that way: `TileLabel`
            // resolves an element's style and never its glyph, precisely because the right glyph
            // for an unreachable lock is domain knowledge (see the comment on `symbol`). The
            // emphases below are the ordinary ones; it is the picture that is special here.
            TileLabel(symbol: symbol,
                      name: store.displayName(of: entityId),
                      icon: .accent,
                      accent: accent, unavailable: unavailable)
        }
        .contentShape(Rectangle()).onTapGesture { store.toggleLock(entityId) }.onLongPressGesture(minimumDuration: 0.35) { navigation.open(entityId) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.map { AccessibilitySummary.lock(store.displayName(of: entityId), $0) } ?? store.displayName(of: entityId))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open controls") { navigation.open(entityId) }
    }
}
