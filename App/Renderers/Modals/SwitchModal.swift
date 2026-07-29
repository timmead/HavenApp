import SwiftUI
import HavenCore
struct SwitchModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId); let on = e?.state == "on"
        let unavailable = e?.state == "unavailable"
        let unknown = e?.state == "unknown"
        VStack {
            // `on` is `state == "on"`, which is `false` for an unreachable switch exactly as it is
            // for one that is genuinely off — so this header claimed "Off" about a switch Home
            // Assistant cannot reach. `unavailable` and `unknown` are read apart because only the
            // former cannot be commanded; see `HomeStore.optimistic`, which the toggle must agree
            // with or it flips and springs back having sent nothing.
            ModalHeader(systemImage: IconMap.symbol(domain: .switchOutlet, deviceClass: e?.deviceClass),
                        title: store.displayName(of: entityId),
                        subtitle: unavailable ? "Unavailable" : (unknown ? "Unknown" : (on ? "On" : "Off")),
                        accent: HavenColor.domain(.switchOutlet), unavailable: unavailable,
                        toggle: Binding(get: { on }, set: { store.setSwitch(entityId, on: $0) }),
                        )
        }
    }
}
