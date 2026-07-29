import SwiftUI
import HavenCore
struct CoverTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation
    var body: some View {
        let e = store.state(entityId); let s = e.map(CoverState.init)
        let open = s?.isOpen ?? false; let accent = HavenColor.domain(.cover)
        let unavailable = e?.isUnavailable ?? false
        GlassTile(active: open, accent: accent, unavailable: unavailable) {
            HStack(alignment: .top, spacing: 0) {
                // The symbol needs no unavailable-specific choice: it is the neutral domain glyph
                // in every case, not an open/closed variant. Only the tint and the name do, and
                // `open` reading `false` for an `unavailable` state string made them right
                // incidentally rather than deliberately.
                TileLabel(symbol: IconMap.symbol(domain: .cover, deviceClass: e?.deviceClass),
                          name: store.displayName(of: entityId),
                          icon: open ? .accent : .secondary,
                          title: open ? .primary : .secondary,
                          accent: accent, unavailable: unavailable)
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
        .contentShape(Rectangle()).onTapGesture { store.openCloseCover(entityId) }.onLongPressGesture(minimumDuration: 0.35) { navigation.open(entityId) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.map { AccessibilitySummary.cover(store.displayName(of: entityId), $0) } ?? store.displayName(of: entityId))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open controls") { navigation.open(entityId) }
    }
}
