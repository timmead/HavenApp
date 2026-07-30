import SwiftUI
import HavenCore
struct GenericTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation
    /// Which surface this tile is on — set by `ConfigurableTile`, and what a tap in
    /// configuration mode removes it from.
    @Environment(\.havenSurface) private var surface
    var body: some View {
        let e = store.state(entityId)
        let unavailable = e?.isUnavailable ?? false
        GlassTile(active: false, accent: .gray, unavailable: unavailable) {
            TileLabel(symbol: "square.dashed",
                      name: store.displayName(of: entityId),
                      accent: .gray, unavailable: unavailable) {
                // Already unconditionally `.secondary`, and already shows the literal raw state
                // string — for an unavailable entity that string *is* "unavailable", so this is
                // an honest reading rather than a false claim, and needs no further guard.
                Text(e?.state ?? "—").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle()).onTapGesture { navigation.open(entityId, on: surface) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AccessibilitySummary.generic(store.displayName(of: entityId), rawState: e?.state ?? "unknown"))
        .accessibilityAddTraits(.isButton)
    }
}
