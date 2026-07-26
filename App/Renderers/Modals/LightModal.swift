import SwiftUI
import HavenCore
struct LightModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let e = store.state(entityId); let s = e.map(LightState.init)
        let accent = HavenColor.domain(.light)
        VStack(spacing: 12) {
            ModalHeader(systemImage: "lightbulb.fill", title: TileName.of(entityId, e),
                        subtitle: (s?.isOn ?? false) ? "On" : "Off", accent: accent,
                        toggle: Binding(get: { s?.isOn ?? false }, set: { store.setLight(entityId, on: $0) })) { dismiss() }
            if s?.supportsBrightness ?? false {
                FacetCard(title: "Brightness") {
                    Slider(value: Binding(get: { Double(s?.brightnessPercent ?? 0) }, set: { store.setBrightness(entityId, percent: Int($0)) }), in: 0...100).tint(accent)
                }
            }
            Spacer()
        }
    }
}
