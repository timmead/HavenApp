import SwiftUI
import HavenCore
struct LightModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var dragPercent: Double?      // non-nil only while dragging
    @State private var dragKelvin: Double?       // non-nil only while dragging

    var body: some View {
        let e = store.state(entityId)
        let s = e.map(LightState.init)
        let accent = HavenColor.domain(.light)
        let name = TileName.of(entityId, e)
        // An off light has no brightness — don't show a stale percentage.
        let live = Double((s?.isOn ?? false) ? (s?.brightnessPercent ?? 0) : 0)
        let range = s?.colorTempRange
        // An off light has no live colour-temperature attribute either — rest at the
        // midpoint of its own range rather than show a stale (or absent) reading.
        let liveKelvin = range.map { r -> Double in
            let mid = Double(r.lowerBound + r.upperBound) / 2
            return (s?.isOn ?? false) ? Double(s?.colorTempKelvin ?? Int(mid)) : mid
        }
        VStack(spacing: 12) {
            ModalHeader(systemImage: IconMap.symbol(domain: .light, deviceClass: e?.deviceClass), title: name,
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
                    .accessibilityLabel("Brightness")
                    .accessibilityValue("\(Int((dragPercent ?? live).rounded()))%")
                    .accessibilityAdjustableAction { direction in
                        let current = dragPercent ?? live
                        let step = 5.0
                        let next = direction == .increment ? min(100, current + step) : max(0, current - step)
                        dragPercent = nil
                        store.setBrightness(entityId, percent: Int(next.rounded()))
                    }
                }
            }
            if let range, let liveKelvin {
                FacetCard(title: "Color Temperature") {
                    // A static warm→cool reference strip, not the slider's own fill — the
                    // interactive control below stays idiom-identical to Brightness (same
                    // drag/commit shape); this is purely the "self-describing" visual cue.
                    LinearGradient(colors: [HavenColor.colorTempWarm, HavenColor.colorTempCool], startPoint: .leading, endPoint: .trailing)
                        .clipShape(Capsule())
                        .frame(height: 4)
                        .accessibilityHidden(true)
                    Slider(value: Binding(get: { dragKelvin ?? liveKelvin },
                                          set: { dragKelvin = $0 }),
                           in: Double(range.lowerBound)...Double(range.upperBound),
                           onEditingChanged: { editing in
                               if !editing, let v = dragKelvin {
                                   store.setColorTemp(entityId, kelvin: Int(v.rounded()))
                                   dragKelvin = nil
                               }
                           })
                    .tint(accent)
                    .accessibilityLabel("Color temperature")
                    .accessibilityValue("\(Int((dragKelvin ?? liveKelvin).rounded())) Kelvin")
                    .accessibilityAdjustableAction { direction in
                        let current = dragKelvin ?? liveKelvin
                        let step = Double(max(1, (range.upperBound - range.lowerBound) / 20))
                        let next = direction == .increment
                            ? min(Double(range.upperBound), current + step)
                            : max(Double(range.lowerBound), current - step)
                        dragKelvin = nil
                        store.setColorTemp(entityId, kelvin: Int(next.rounded()))
                    }
                    Text("\(Int((dragKelvin ?? liveKelvin).rounded()))K")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)     // already spoken as the slider's value
                }
            }
            Spacer()
        }
        .onChange(of: s?.isOn ?? false) { _, isOn in
            if !isOn { dragPercent = nil; dragKelvin = nil }
        }
    }
}
