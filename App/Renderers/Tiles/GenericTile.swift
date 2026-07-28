import SwiftUI
import HavenCore
struct GenericTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId)
        let unavailable = e?.isUnavailable ?? false
        GlassTile(active: false, accent: .gray, unavailable: unavailable) {
            TileLabel(symbol: "square.dashed",
                      name: TileName.of(entityId, e),
                      accent: .gray, unavailable: unavailable) {
                // Already unconditionally `.secondary`, and already shows the literal raw state
                // string — for an unavailable entity that string *is* "unavailable", so this is
                // an honest reading rather than a false claim, and needs no further guard.
                Text(e?.state ?? "—").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle()).onTapGesture { store.presented = entityId }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AccessibilitySummary.generic(TileName.of(entityId, e), rawState: e?.state ?? "unknown"))
        .accessibilityAddTraits(.isButton)
    }
}
