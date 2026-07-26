import SwiftUI
import HavenCore
struct ClimateModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let e = store.state(entityId); let s = e.map(ClimateState.init)
        let accent = HavenColor.domain(.climate)
        VStack(spacing: 12) {
            ModalHeader(systemImage: "thermometer.medium", title: TileName.of(entityId, e),
                        subtitle: s.map { $0.isOn ? "\($0.hvacMode.capitalized)" : "Off" } ?? "", accent: accent,
                        toggle: Binding(get: { s?.isOn ?? false }, set: { store.setClimateMode(entityId, mode: $0 ? (s?.modes.first { $0 != "off" } ?? "heat") : "off") })) { dismiss() }
            FacetCard {
                HStack {
                    Button { if let t = s?.targetTemp { store.setClimateTemp(entityId, temp: t - 1) } } label: { Image(systemName: "minus.circle.fill").font(.title) }
                    Spacer()
                    VStack { Text(s?.targetTemp.map { "\(Int($0))°" } ?? "—").font(.system(size: 40, weight: .bold))
                        Text(s?.currentTemp.map { "Now \(Int($0))°" } ?? "").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button { if let t = s?.targetTemp { store.setClimateTemp(entityId, temp: t + 1) } } label: { Image(systemName: "plus.circle.fill").font(.title) }
                }.tint(accent)
            }
            if let modes = s?.modes.filter({ $0 != "off" }), modes.count > 1 {
                // When the unit is off, "off" isn't among the selectable modes — show the
                // first real mode as the selection rather than leaving the control blank.
                let currentMode = modes.contains(s?.hvacMode ?? "") ? (s?.hvacMode ?? "") : (modes.first ?? "")
                FacetCard(title: "Mode") { HavenSegmented(options: modes, selection: Binding(get: { currentMode }, set: { store.setClimateMode(entityId, mode: $0) }), label: { $0.capitalized }, accent: accent) }
            }
            if let fans = s?.fanModes, fans.count > 1 {
                FacetCard(title: "Fan") { HavenSegmented(options: fans, selection: Binding(get: { s?.fanMode ?? fans[0] }, set: { store.setFanMode(entityId, mode: $0) }), label: { $0.capitalized }, accent: accent) }
            }
            Spacer()
        }
    }
}
