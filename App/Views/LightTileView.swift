import SwiftUI
import HavenCore

struct LightTileView: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let on = store.isOn(entityId)
        Button { store.toggleLightOptimistic(entityId) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: on ? "lightbulb.fill" : "lightbulb")
                    .font(.title2).symbolRenderingMode(.hierarchical)
                Text(entityId.replacingOccurrences(of: "light.", with: "").replacingOccurrences(of: "_", with: " "))
                    .font(.caption).lineLimit(1)
                Text(on ? "On" : "Off").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .buttonStyle(.plain)
        .background(on ? Color.yellow.opacity(0.25) : Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
