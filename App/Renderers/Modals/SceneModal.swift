import SwiftUI
import HavenCore
struct SceneModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let e = store.state(entityId)
        // **This modal had no notion of unreachability at all** — full-strength accent, nothing
        // said about the state, and a Run button that looked entirely live. `store.run` already
        // refuses an unreachable entity, so tapping it did nothing and said nothing about why,
        // which `ModalHeader` names as the least honest of the options.
        let unavailable = e?.isUnavailable ?? false
        VStack(spacing: 14) {
            ModalHeader(systemImage: IconMap.symbol(domain: Domain.of(entityId), deviceClass: nil),
                        title: TileName.of(entityId, e), subtitle: "",
                        accent: HavenColor.domain(.scene), unavailable: unavailable)
            Button { store.run(entityId); dismiss() } label: { Text("Run").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(HavenColor.domain(.scene))
                .disabled(unavailable)
        }
    }
}
