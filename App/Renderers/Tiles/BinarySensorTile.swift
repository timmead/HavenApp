import SwiftUI
import HavenCore
struct BinarySensorTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId)
        GlassTile(active: false, accent: .gray) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: IconMap.symbol(domain: Domain.of(entityId), deviceClass: e?.deviceClass))
                    .font(.system(size: 20)).foregroundStyle(.secondary).symbolRenderingMode(.hierarchical)
                Spacer(minLength: 2)
                Text(TileName.of(entityId, e)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            }
        }
    }
}
