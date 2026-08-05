import SwiftUI
import HavenCore
struct LightModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @State private var dragPercent: Double?      // non-nil only while dragging
    @State private var dragKelvin: Double?       // non-nil only while dragging

    var body: some View {
        let e = store.state(entityId)
        let s = e.map(LightState.init)
        let accent = HavenColor.domain(.light)
        let name = store.displayName(of: entityId)
        // An off light has no brightness — don't show a stale percentage.
        let live = Double((s?.isOn ?? false) ? (s?.brightnessPercent ?? 0) : 0)
        let range = s?.colorTempRange
        // An off light has no live colour-temperature attribute either — rest at the
        // midpoint of its own range rather than show a stale (or absent) reading.
        let liveKelvin = range.map { r -> Double in
            let mid = Double(r.lowerBound + r.upperBound) / 2
            return (s?.isOn ?? false) ? Double(s?.colorTempKelvin ?? Int(mid)) : mid
        }
        // `isOn` reads `false` for an `unavailable` state string exactly as it would for a light
        // that is genuinely switched off, so left alone this header said "Off" about a bulb Home
        // Assistant cannot reach — the state claim the tile beside it was struck through to avoid.
        //
        // `unavailable` and `unknown` are read apart rather than folded into `isUnavailable`: an
        // unreachable light cannot be commanded, while an `unknown` one is reachable and simply
        // has not reported yet, so its toggle stays live. `HomeStore.optimistic` makes the same
        // distinction on the command side, and the toggle must agree with it or it would flip and
        // spring back having sent nothing.
        let unavailable = e?.state == "unavailable"
        let unknown = e?.state == "unknown"
        VStack(spacing: 12) {
            ModalHeader(systemImage: IconMap.symbol(domain: .light, deviceClass: e?.deviceClass), title: name,
                        subtitle: unavailable ? "Unavailable"
                            : (unknown ? "Unknown" : ((s?.isOn ?? false) ? "On" : "Off")),
                        accent: accent, unavailable: unavailable,
                        toggle: Binding(get: { s?.isOn ?? false }, set: { store.setLight(entityId, on: $0) }),
                        )
            if s?.supportsBrightness ?? false {
                FacetCard(title: "Brightness") {
                    // Cleared after an adjustment, not pinned — `setBrightness` writes
                    // `LightOptimistic.brightness` into `states` synchronously, and `CommitSlider`'s
                    // doc comment carries the history of why pinning it is now the bug rather than
                    // the fix.
                    CommitSlider(value: live, preview: $dragPercent, in: 0...100,
                                 adjustmentStep: 5, tint: accent, label: "Brightness",
                                 valueDescription: { "\(Int($0.rounded()))%" },
                                 onCommit: { store.setBrightness(entityId, percent: Int($0.rounded())) })
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
                    // A twentieth of the light's own range per swipe, floored at 1K, and computed
                    // in whole kelvin here rather than from the slider's `Double` bounds — the
                    // division is integer, and an odd-width range gives a different number if it
                    // isn't.
                    //
                    // Pinned after an adjustment, unlike brightness, since `setColorTemp` writes
                    // nothing into `states`.
                    let kelvinStep = Double(max(1, (range.upperBound - range.lowerBound) / 20))
                    CommitSlider(value: liveKelvin, preview: $dragKelvin,
                                 in: Double(range.lowerBound)...Double(range.upperBound),
                                 adjustmentStep: kelvinStep, tint: accent, label: "Color temperature",
                                 pinsPreviewAfterAdjusting: true,
                                 valueDescription: { "\(Int($0.rounded())) Kelvin" },
                                 onCommit: { store.setColorTemp(entityId, kelvin: Int($0.rounded())) })
                    Text("\(Int((dragKelvin ?? liveKelvin).rounded()))K")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)     // already spoken as the slider's value
                }
            }
        }
        .onChange(of: s?.isOn ?? false) { _, isOn in
            if !isOn { dragPercent = nil; dragKelvin = nil }
        }
    }
}
