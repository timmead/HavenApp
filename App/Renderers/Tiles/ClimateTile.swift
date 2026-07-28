import SwiftUI
import HavenCore
struct ClimateTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation
    var body: some View {
        let e = store.state(entityId); let s = e.map(ClimateState.init)
        let on = s?.isOn ?? false; let accent = HavenColor.domain(.climate)
        let unavailable = e?.isUnavailable ?? false
        GlassTile(active: on, accent: accent, unavailable: unavailable) {
            VStack(alignment: .leading, spacing: 4) {
                // Unlike the other tiles' icons, this one is always tinted `accent` regardless of
                // on/off by design — but that means an unreachable thermostat needs its own guard
                // rather than inheriting one from an `on`/`off` check that was never gating it.
                Image(systemName: "thermometer.medium").font(.system(size: 20)).foregroundStyle(tileColor(.accent, unavailable: unavailable, accent: accent)).symbolRenderingMode(.hierarchical)
                Spacer(minLength: 2)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    // Unguarded, this was a bigger version of the same problem the icon above
                    // fixes: `targetTemp` is read straight from attributes regardless of state, so
                    // an unreachable thermostat that still has a cached `temperature` attribute
                    // would show its last-known target in full accent colour — a state claim in
                    // the tile's most prominent text. Same guard shape as the icon.
                    Text(s?.targetTemp.map { "\(Int($0))°" } ?? "—").font(.system(size: 24, weight: .bold)).foregroundStyle(tileColor(.accent, unavailable: unavailable, accent: accent))
                    // Already unconditionally `.secondary` regardless of availability — a
                    // hierarchy choice, not an on/off one — so no guard is needed here to satisfy
                    // "unavailable text is secondary". Left untouched.
                    Text(s.map { "\(TileName.words($0.hvacMode))\($0.fanMode.map { " · fan \(TileName.words($0))" } ?? "")" } ?? "").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle()).onTapGesture { navigation.presentedEntityId = entityId }.onLongPressGesture(minimumDuration: 0.35) { navigation.presentedEntityId = entityId }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.map { AccessibilitySummary.climate(TileName.of(entityId, e), $0) } ?? TileName.of(entityId, e))
        .accessibilityAddTraits(.isButton)
    }
}
