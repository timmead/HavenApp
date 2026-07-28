import SwiftUI
import HavenCore
struct ClimateModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId); let s = e.map(ClimateState.init)
        let accent = HavenColor.domain(.climate)
        // `ClimateState.isOn` already excludes `unavailable`/`unknown`, so this header did not
        // claim a *mode* for an unreachable thermostat — but it fell through to "Off", which is
        // the same false claim in different words. Named explicitly instead.
        //
        // `unavailable` and `unknown` are read apart because only the former cannot be commanded;
        // the toggle has to agree with `HomeStore`'s command guard or it flips and springs back
        // having sent nothing.
        let unavailable = e?.state == "unavailable"
        let unknown = e?.state == "unknown"
        VStack(spacing: 12) {
            ModalHeader(systemImage: IconMap.symbol(domain: .climate, deviceClass: e?.deviceClass),
                        title: TileName.of(entityId, e),
                        subtitle: unavailable ? "Unavailable"
                            : (unknown ? "Unknown" : (s.map { $0.isOn ? TileName.words($0.hvacMode) : "Off" } ?? "")),
                        accent: accent, unavailable: unavailable,
                        toggle: Binding(get: { s?.isOn ?? false }, set: { store.setClimateMode(entityId, mode: $0 ? (s?.modes.first { $0 != "off" } ?? "heat") : "off") }),
                        )
            FacetCard {
                HStack {
                    Button { if let t = s?.targetTemp { store.setClimateTemp(entityId, temp: t - 1) } } label: { Image(systemName: "minus.circle.fill").font(.title) }
                        .accessibilityLabel("Decrease target temperature")
                    Spacer()
                    VStack { Text(s?.targetTemp.map { "\(Int($0))°" } ?? "—").font(.system(size: 40, weight: .bold))
                        Text(s?.currentTemp.map { "Now \(Int($0))°" } ?? "").font(.caption).foregroundStyle(.secondary) }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(climateReadout(s))
                    Spacer()
                    Button { if let t = s?.targetTemp { store.setClimateTemp(entityId, temp: t + 1) } } label: { Image(systemName: "plus.circle.fill").font(.title) }
                        .accessibilityLabel("Increase target temperature")
                }.tint(accent)
            }
            if let modes = s?.modes.filter({ $0 != "off" }), modes.count > 1 {
                // When the unit is off, "off" isn't among the selectable modes — show the
                // first real mode as the selection rather than leaving the control blank.
                let currentMode = modes.contains(s?.hvacMode ?? "") ? (s?.hvacMode ?? "") : (modes.first ?? "")
                FacetCard(title: "Mode") { HavenSegmented(options: modes, selection: Binding(get: { currentMode }, set: { store.setClimateMode(entityId, mode: $0) }), label: TileName.words, accent: accent) }
            }
            if let fans = s?.fanModes, fans.count > 1 {
                FacetCard(title: "Fan") { HavenSegmented(options: fans, selection: Binding(get: { s?.fanMode ?? fans[0] }, set: { store.setFanMode(entityId, mode: $0) }), label: TileName.words, accent: accent) }
            }
        }
    }

    /// Combined VoiceOver label for the target/current readout — mirrors the two
    /// separately-styled `Text` lines it replaces without losing either value.
    private func climateReadout(_ s: ClimateState?) -> String {
        let target = s?.targetTemp.map { "Target \(Int($0))°" } ?? "No target set"
        guard let current = s?.currentTemp else { return target }
        return "\(target), currently \(Int(current))°"
    }
}
