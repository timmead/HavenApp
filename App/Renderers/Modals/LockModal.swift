import SwiftUI
import HavenCore
struct LockModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let e = store.state(entityId); let s = e.map(LockState.init)
        let locked = s?.isLocked ?? false; let jammed = s?.isJammed ?? false
        let subtitle = jammed ? "Jammed" : (locked ? "Locked" : "Unlocked")
        let symbol = jammed ? "lock.trianglebadge.exclamationmark" : (locked ? "lock.fill" : "lock.open.fill")
        // A jammed lock's true position is unknown — omit the toggle rather than show a
        // control that implies a known (and likely wrong) locked/unlocked state.
        let toggleBinding: Binding<Bool>? = jammed ? nil : Binding(get: { locked }, set: { _ in store.toggleLock(entityId) })
        VStack {
            ModalHeader(systemImage: symbol, title: TileName.of(entityId, e), subtitle: subtitle,
                        accent: jammed ? HavenColor.domain(.light) : HavenColor.domain(.lock),
                        toggle: toggleBinding) { dismiss() }
            Spacer()
        }
    }
}
