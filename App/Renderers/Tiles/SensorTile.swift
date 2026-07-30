import SwiftUI
import HavenCore
struct SensorTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation
    /// Which surface this tile is on — set by `ConfigurableTile`, and what a tap in
    /// configuration mode removes it from.
    @Environment(\.havenSurface) private var surface
    var body: some View {
        let e = store.state(entityId); let s = e.map(SensorState.init)
        let unavailable = e?.isUnavailable ?? false
        GlassTile(active: false, accent: .gray, unavailable: unavailable) {
            // **The tile the sweep missed.** Its name had no `foregroundStyle` at all, so it
            // defaulted to `.primary` and stayed full-strength for a sensor nothing could reach.
            // There is now no way to render this label without an emphasis going through
            // `resolved(unavailable:)`, which is the point of the component.
            //
            // The icon is unconditionally `.secondary`: a sensor is a reading, not a state, and
            // has no "active" to tint for.
            TileLabel(symbol: IconMap.symbol(domain: .sensor, deviceClass: e?.deviceClass),
                      name: store.displayName(of: entityId),
                      accent: .gray, unavailable: unavailable) {
                // Already unconditionally `.secondary` — a hierarchy choice, not an on/off one —
                // so it already satisfies "unavailable text is secondary" with no change. For an
                // unreachable sensor the value string *is* "unavailable", which is honest.
                Text([s?.value, s?.unit].compactMap { $0 }.joined(separator: " "))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle()).onTapGesture { navigation.open(entityId, on: surface) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.map { AccessibilitySummary.sensor(store.displayName(of: entityId), $0) } ?? store.displayName(of: entityId))
        .accessibilityAddTraits(.isButton)
    }
}
