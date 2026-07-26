import SwiftUI
import HavenCore
struct GenericModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let e = store.state(entityId)
        VStack {
            ModalHeader(systemImage: IconMap.symbol(domain: Domain.of(entityId), deviceClass: e?.deviceClass),
                        title: TileName.of(entityId, e), subtitle: e?.state ?? "—", accent: .gray) { dismiss() }
            Spacer()
        }
    }
}
