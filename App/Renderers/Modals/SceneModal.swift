import SwiftUI
import HavenCore
struct SceneModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let e = store.state(entityId)
        VStack(spacing: 14) {
            ModalHeader(systemImage: IconMap.symbol(domain: Domain.of(entityId), deviceClass: nil), title: TileName.of(entityId, e), subtitle: "", accent: HavenColor.domain(.scene))
            Button { store.run(entityId); dismiss() } label: { Text("Run").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(HavenColor.domain(.scene))
            Spacer()
        }
    }
}
