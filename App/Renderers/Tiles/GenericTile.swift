import SwiftUI
import HavenCore
struct GenericTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId)
        GlassTile(active: false, accent: .gray) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: "square.dashed").font(.system(size: 20)).foregroundStyle(.secondary)
                Spacer(minLength: 2); Text(TileName.of(entityId, e)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                Text(e?.state ?? "—").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle()).onTapGesture { store.presented = entityId }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AccessibilitySummary.generic(TileName.of(entityId, e), rawState: e?.state ?? "unknown"))
        .accessibilityAddTraits(.isButton)
    }
}
