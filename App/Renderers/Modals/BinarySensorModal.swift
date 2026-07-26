import SwiftUI
import HavenCore

struct BinarySensorModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let e = store.state(entityId)
        let s = e.map(BinarySensorState.init)
        VStack {
            ModalHeader(systemImage: IconMap.symbol(domain: .binarySensor, deviceClass: e?.deviceClass),
                        title: TileName.of(entityId, e),
                        subtitle: (s?.isActive ?? false) ? "Active" : "Clear",
                        accent: (s?.isActive ?? false) ? .orange : .gray) { dismiss() }
            Spacer()
        }
    }
}
