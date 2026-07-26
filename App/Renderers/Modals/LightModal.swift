import SwiftUI
import HavenCore
struct LightModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var dragPercent: Double?      // non-nil only while dragging

    var body: some View {
        let e = store.state(entityId)
        let s = e.map(LightState.init)
        let accent = HavenColor.domain(.light)
        // An off light has no brightness — don't show a stale percentage.
        let live = Double((s?.isOn ?? false) ? (s?.brightnessPercent ?? 0) : 0)
        VStack(spacing: 12) {
            ModalHeader(systemImage: IconMap.symbol(domain: .light, deviceClass: e?.deviceClass), title: TileName.of(entityId, e),
                        subtitle: (s?.isOn ?? false) ? "On" : "Off", accent: accent,
                        toggle: Binding(get: { s?.isOn ?? false }, set: { store.setLight(entityId, on: $0) })) { dismiss() }
            if s?.supportsBrightness ?? false {
                FacetCard(title: "Brightness") {
                    Slider(value: Binding(get: { dragPercent ?? live },
                                          set: { dragPercent = $0 }),
                           in: 0...100,
                           onEditingChanged: { editing in
                               if !editing, let v = dragPercent {
                                   store.setBrightness(entityId, percent: Int(v.rounded()))
                                   dragPercent = nil
                               }
                           })
                    .tint(accent)
                }
            }
            Spacer()
        }
        .onChange(of: s?.isOn ?? false) { _, isOn in
            if !isOn { dragPercent = nil }
        }
    }
}
