import SwiftUI
import HavenCore
struct CoverTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId); let s = e.map(CoverState.init)
        let open = s?.isOpen ?? false; let accent = HavenColor.domain(.cover)
        let unavailable = e?.isUnavailable ?? false
        GlassTile(active: open, accent: accent, unavailable: unavailable) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    // `open` already reads `false` for an `unavailable` state string, same as for a
                    // genuinely closed cover, so this guard is currently redundant with that — but
                    // stated explicitly rather than left to depend on `CoverState.isOpen`'s exact
                    // definition never changing. The symbol itself needs no such guard: it is
                    // already the neutral domain glyph in every case, not an open/closed variant.
                    Image(systemName: IconMap.symbol(domain: .cover, deviceClass: e?.deviceClass)).font(.system(size: 20)).foregroundStyle(unavailable ? .secondary : (open ? accent : .secondary)).symbolRenderingMode(.hierarchical)
                    Spacer(minLength: 2); Text(TileName.of(entityId, e)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).foregroundStyle(open ? .primary : .secondary)
                }
                // Unlike the light, this is shown at every position including 0 — a closed shade
                // has a real, meaningful position — so a drag up from the bottom genuinely opens
                // it, and `CoverOptimistic.position` moves the open/closed state along with the
                // number so the tile's tint and the bar can't disagree. Hence `minimum: 0`: for a
                // cover, dragging to the bottom is closing it, which is a legitimate thing to ask
                // for and leaves the control on screen.
                if let pos = s?.positionPercent {
                    Spacer(minLength: 6)
                    PipSlider(percent: pos, accent: accent,
                              label: "Position",
                              onCommit: { store.setCoverPosition(entityId, percent: $0) },
                              onTap: { store.openCloseCover(entityId) })
                        .padding(.vertical, 2)
                }
            }
        }
        .contentShape(Rectangle()).onTapGesture { store.openCloseCover(entityId) }.onLongPressGesture(minimumDuration: 0.35) { store.presented = entityId }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.map { AccessibilitySummary.cover(TileName.of(entityId, e), $0) } ?? TileName.of(entityId, e))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open controls") { store.presented = entityId }
    }
}
