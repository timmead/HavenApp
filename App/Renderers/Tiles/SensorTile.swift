import SwiftUI
import HavenCore

/// The two approved sensor tile renderings.
enum SensorTileSize {
    /// 1×1. Icon, name, reading.
    case small
    /// 2×1. The same reading over a day of itself — see `SensorSparkline`.
    case wide
}

extension SensorTileSize {
    /// The rendering a span asks for. See `DeviceTileView.tile`.
    init(span: TileSpan) {
        self = span.columns >= 2 ? .wide : .small
    }
}

struct SensorTile: View {
    let entityId: String
    var size: SensorTileSize = .small
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation
    /// Which surface this tile is on — set by `ConfigurableTile`, and what a tap in
    /// configuration mode removes it from.
    @Environment(\.havenSurface) private var surface
    var body: some View {
        switch size {
        case .small: small
        case .wide: wide
        }
    }

    /// The 2×1: the same reading, over a day of itself.
    ///
    /// **The line is behind the text, not beside it.** A half-row tile has room for one thing to be
    /// read and one thing to be sensed, and putting them in separate columns makes two small things
    /// where the point is one reading with its own recent past behind it.
    ///
    /// The history load is `.task`, so it happens when the tile appears and never again — see
    /// `refreshPolicy`.
    private var wide: some View {
        let e = store.state(entityId)
        let s = e.map(SensorState.init)
        let unavailable = e?.isUnavailable ?? false
        return GlassTile(active: false, accent: .gray, unavailable: unavailable) {
            TileLabel(symbol: IconMap.symbol(domain: .sensor, deviceClass: e?.deviceClass),
                      name: store.displayName(of: entityId),
                      accent: .gray, unavailable: unavailable) {
                Text([s?.value, s?.unit].compactMap { $0 }.joined(separator: " "))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            // Fills the cell so the background behind it does too — a background is sized to what it
            // is behind, and a label only as wide as its text would carry a sparkline only that
            // wide. Under an unspecified proposal this still measures as the label's own ideal
            // height, which is what keeps the row honest.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // **A background, not a `ZStack` member — and the difference is the whole tile.**
            //
            // A background is laid out to fit whatever it is behind and never contributes to the
            // parent's ideal size; a `ZStack` member does. `Chart` reports a large ideal height, and
            // `RoomGrid` measures its row from the tallest *single-row* tile — which a 2×1 sensor is.
            // So as a stack member this chart silently made every row in the room half again as
            // tall, and only once its history had loaded, which is why it looked briefly correct
            // and then grew.
            //
            // The rule this tile now obeys: **what a tile measures must be what a tile draws.** The
            // camera tile learned the same thing from `aspectRatio(contentMode: .fill)` reporting an
            // oversized frame to its parent.
            .background(alignment: .bottomLeading) {
                SensorSparkline(series: store.history(entityId, Self.range),
                                accent: HavenColor.domain(.sensor))
                    .padding(.top, 18)
                    .padding(.horizontal, -2)
            }
        }
        .task { await store.loadHistory(entityId, range: Self.range) }
        .contentShape(Rectangle()).onTapGesture { navigation.open(entityId, on: surface) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.map { AccessibilitySummary.sensor(store.displayName(of: entityId), $0) } ?? store.displayName(of: entityId))
        .accessibilityAddTraits(.isButton)
    }

    /// **The one range a tile ever asks for, and it is not polled.**
    ///
    /// A day, because `HistoryRange` has no shorter case and a 24-hour shape is what a glance wants.
    /// Fetched once when the tile appears: `HistoryCache` deduplicates in-flight requests and holds
    /// the answer for five minutes, so a dashboard of wide sensors costs one request each per five
    /// minutes rather than a stream. This is the same bargain `CameraTile.refreshPolicy` documents —
    /// a dashboard is glanced at, and paying continuously for it is how a home app becomes a battery
    /// complaint.
    private static let range: HistoryRange = .day

    private var small: some View {
        let e = store.state(entityId); let s = e.map(SensorState.init)
        let unavailable = e?.isUnavailable ?? false
        return GlassTile(active: false, accent: .gray, unavailable: unavailable) {
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
