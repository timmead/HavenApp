import SwiftUI
import HavenCore
struct LockModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let e = store.state(entityId); let s = e.map(LockState.init); let locked = s?.isLocked ?? false
        VStack {
            ModalHeader(systemImage: locked ? "lock.fill" : "lock.open.fill", title: TileName.of(entityId, e), subtitle: locked ? "Locked" : "Unlocked", accent: HavenColor.domain(.lock),
                        toggle: Binding(get: { locked }, set: { _ in store.toggleLock(entityId) })) { dismiss() }
            Spacer()
        }
    }
}
