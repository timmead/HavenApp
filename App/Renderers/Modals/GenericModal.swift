import SwiftUI
import HavenCore
struct GenericModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let e = store.state(entityId)
        VStack(spacing: 12) {
            ModalHeader(systemImage: "square.dashed", title: TileName.of(entityId, e), subtitle: e?.state ?? "—", accent: .gray) { dismiss() }
            FacetCard(title: "Attributes") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach((e?.attributes.keys.sorted() ?? []), id: \.self) { k in
                        HStack { Text(k).font(.caption).foregroundStyle(.secondary); Spacer(); Text(String(describing: e?.attributes[k] ?? .null)).font(.caption).lineLimit(1) }
                    }
                }
            }
            Spacer()
        }
    }
}
