import SwiftUI
import HavenCore
struct SensorTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId); let s = e.map(SensorState.init)
        let unavailable = e?.isUnavailable ?? false
        GlassTile(active: false, accent: .gray, unavailable: unavailable) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: IconMap.symbol(domain: .sensor, deviceClass: e?.deviceClass)).font(.system(size: 20)).foregroundStyle(.secondary).symbolRenderingMode(.hierarchical)
                Spacer(minLength: 2)
                // Had no `foregroundStyle` at all, which defaults to `.primary` regardless of
                // reachability — the one this feature exists to catch.
                Text(TileName.of(entityId, e)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(unavailable ? .secondary : .primary)
                // Already unconditionally `.secondary` — a hierarchy choice, not an on/off one —
                // so it already satisfies "unavailable text is secondary" with no change.
                Text([s?.value, s?.unit].compactMap { $0 }.joined(separator: " ")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle()).onTapGesture { store.presented = entityId }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.map { AccessibilitySummary.sensor(TileName.of(entityId, e), $0) } ?? TileName.of(entityId, e))
        .accessibilityAddTraits(.isButton)
    }
}
