import SwiftUI
import HavenCore
struct SwitchModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId); let on = e?.state == "on"
        VStack {
            ModalHeader(systemImage: IconMap.symbol(domain: .switchOutlet, deviceClass: e?.deviceClass), title: TileName.of(entityId, e), subtitle: on ? "On" : "Off", accent: HavenColor.domain(.switchOutlet),
                        toggle: Binding(get: { on }, set: { store.setSwitch(entityId, on: $0) }))
        }
    }
}
