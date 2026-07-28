import SwiftUI
import HavenCore
struct ClimateTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId); let s = e.map(ClimateState.init)
        let on = s?.isOn ?? false; let accent = HavenColor.domain(.climate)
        let unavailable = e?.isUnavailable ?? false
        GlassTile(active: on, accent: accent, unavailable: unavailable) {
            VStack(alignment: .leading, spacing: 4) {
                // Unlike the other tiles' icons, this one is always tinted `accent` regardless of
                // on/off by design — but that means an unreachable thermostat needs its own guard
                // rather than inheriting one from an `on`/`off` check that was never gating it.
                Image(systemName: "thermometer.medium").font(.system(size: 20)).foregroundStyle(unavailable ? .secondary : accent).symbolRenderingMode(.hierarchical)
                Spacer(minLength: 2)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(s?.targetTemp.map { "\(Int($0))°" } ?? "—").font(.system(size: 24, weight: .bold)).foregroundStyle(accent)
                    Text(s.map { "\(TileName.words($0.hvacMode))\($0.fanMode.map { " · fan \(TileName.words($0))" } ?? "")" } ?? "").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle()).onTapGesture { store.presented = entityId }.onLongPressGesture(minimumDuration: 0.35) { store.presented = entityId }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.map { AccessibilitySummary.climate(TileName.of(entityId, e), $0) } ?? TileName.of(entityId, e))
        .accessibilityAddTraits(.isButton)
    }
}
