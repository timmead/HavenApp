#if DEBUG
import SwiftUI
import HavenCore

/// Every tile renderer, in the states that have historically been got wrong — on, off, and
/// **unreachable** — on one canvas.
///
/// This exists because the tiles are the one part of the app with no other verification. Nothing in
/// either test suite renders a view, so the sweep that dimmed unreachable tiles
/// (`5e67b60`/`6a3bebc`/`e6ebe54`) was applied by hand, tile by tile, and `SensorTile`'s own comment
/// records that it was missed the first time round — it had no `foregroundStyle` at all. A gallery
/// makes "did every tile get it" a thing you look at once rather than eleven files you re-read.
///
/// `#if DEBUG` so none of this is in a shipping build. Render it with Xcode's canvas, or via the
/// preview tooling, on `App/Renderers/TileGallery.swift`.
///
/// **Not included, deliberately:** `CameraTile` and `MediaPlayerTile`'s 4×2 `large` size, both of
/// which fetch artwork over the network from a live Home Assistant. A gallery that renders
/// differently depending on whether a request happened to come back is not a baseline you can
/// compare against.
/// Split in two because a preview snapshot captures one screen, not a scroll view's full content —
/// a single gallery would leave half the tiles unverified below the fold, which is precisely the
/// "assumed rather than looked at" this exists to end.
struct TileGallery: View {
    enum Half { case first, second }
    let half: Half

    /// One store, pre-loaded with a fixture per case below. The tiles read `@Environment`, so this
    /// is the only way to drive them.
    @State private var store = TileGallery.populatedStore()
    /// The tiles write their long-press target into this. Nothing here presents a modal, but the
    /// environment has to hold one or every tile traps on a missing value.
    @State private var navigation = Navigation()

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch half {
                case .first:
                    section("Light") { ids("light", ["on", "off", "unavailable"]) }
                    section("Switch") { ids("switch", ["on", "off", "unavailable"]) }
                    section("Cover") { ids("cover", ["open", "closed", "unavailable"]) }
                    // Four, not three: `unavailable` must render `questionmark.circle` and **not**
                    // either padlock glyph — the one place in the tiles where the *symbol*, not
                    // just its colour, is a state claim. See `LockTile`.
                    section("Lock") { ids("lock", ["locked", "unlocked", "jammed", "unavailable"]) }
                    // The unavailable case here is the most prominent state claim on any tile: a
                    // thermostat's target temperature is read straight from a cached attribute, so
                    // an unreachable one has a number to show whether or not it means anything.
                    section("Climate") { ids("climate", ["on", "off", "unavailable"]) }
                case .second:
                    section("Scene") { ids("scene", ["idle", "unavailable"]) }
                    // The tile the original sweep actually missed.
                    section("Sensor") { ids("sensor", ["value", "unavailable"]) }
                    section("Binary sensor") { ids("binary_sensor", ["active", "clear", "unavailable"]) }
                    section("Generic") { ids("generic", ["idle", "unavailable"]) }
                    section("Media player — 1×1") { ids("media_player", ["playing", "idle", "unavailable"]) }
                    mediaWide
                }
            }
            .padding()
        }
        .environment(store)
        .environment(navigation)
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func ids(_ domain: String, _ cases: [String]) -> some View {
        LazyVGrid(columns: Self.columns, spacing: 10) {
            ForEach(cases, id: \.self) { name in
                DeviceTileView(entityId: "\(domain).\(name)")
            }
        }
    }

    /// The 2×1 size, which took its own commit to get struck (`e6ebe54`) after the 1×1 had already
    /// been done — so it is worth seeing beside its sibling rather than assumed to match.
    private var mediaWide: some View {
        section("Media player — 2×1") {
            VStack(spacing: 10) {
                MediaPlayerTile(entityId: "media_player.playing", size: .wide)
                MediaPlayerTile(entityId: "media_player.unavailable", size: .wide)
            }
        }
    }

    // MARK: - Fixtures

    @MainActor
    private static func populatedStore() -> HomeStore {
        let store = HomeStore()
        func set(_ id: String, _ state: String, _ attributes: [String: JSONValue] = [:]) {
            store.states[id] = EntityState(entityId: id, state: state, attributes: attributes,
                                           lastUpdated: Date(timeIntervalSince1970: 0))
        }
        set("light.on", "on", ["friendly_name": .string("Kitchen"), "brightness": .int(153)])
        set("light.off", "off", ["friendly_name": .string("Hallway")])
        set("light.unavailable", "unavailable", ["friendly_name": .string("Porch")])

        set("switch.on", "on", ["friendly_name": .string("Fan")])
        set("switch.off", "off", ["friendly_name": .string("Heater")])
        set("switch.unavailable", "unavailable", ["friendly_name": .string("Pump")])

        set("cover.open", "open", ["friendly_name": .string("Blinds"), "current_position": .int(70)])
        set("cover.closed", "closed", ["friendly_name": .string("Garage"), "current_position": .int(0)])
        set("cover.unavailable", "unavailable", ["friendly_name": .string("Awning")])

        set("lock.locked", "locked", ["friendly_name": .string("Front")])
        set("lock.unlocked", "unlocked", ["friendly_name": .string("Back")])
        set("lock.jammed", "jammed", ["friendly_name": .string("Side")])
        set("lock.unavailable", "unavailable", ["friendly_name": .string("Shed")])

        set("climate.on", "heat", ["friendly_name": .string("Lounge"), "temperature": .double(21),
                                   "fan_mode": .string("auto")])
        set("climate.off", "off", ["friendly_name": .string("Study"), "temperature": .double(18)])
        set("climate.unavailable", "unavailable", ["friendly_name": .string("Loft"),
                                                   "temperature": .double(23)])

        set("scene.idle", "scening", ["friendly_name": .string("Movie")])
        set("scene.unavailable", "unavailable", ["friendly_name": .string("Away")])

        set("sensor.value", "21.4", ["friendly_name": .string("Temp"),
                                     "device_class": .string("temperature"),
                                     "unit_of_measurement": .string("°C")])
        set("sensor.unavailable", "unavailable", ["friendly_name": .string("Humidity"),
                                                  "device_class": .string("humidity")])

        set("binary_sensor.active", "on", ["friendly_name": .string("Door"),
                                           "device_class": .string("door")])
        set("binary_sensor.clear", "off", ["friendly_name": .string("Window"),
                                           "device_class": .string("window")])
        set("binary_sensor.unavailable", "unavailable", ["friendly_name": .string("Motion"),
                                                         "device_class": .string("motion")])

        set("generic.idle", "idle", ["friendly_name": .string("Thing")])
        set("generic.unavailable", "unavailable", ["friendly_name": .string("Other")])

        set("media_player.playing", "playing", ["friendly_name": .string("Speaker"),
                                                "media_title": .string("A Song"),
                                                "media_artist": .string("An Artist"),
                                                "volume_level": .double(0.4),
                                                "supported_features": .int(4)])
        set("media_player.idle", "idle", ["friendly_name": .string("TV")])
        set("media_player.unavailable", "unavailable", ["friendly_name": .string("Radio")])
        return store
    }
}

#Preview("Tiles 1 — light, switch, cover, lock, climate") {
    TileGallery(half: .first)
}

#Preview("Tiles 2 — scene, sensor, binary, generic, media") {
    TileGallery(half: .second)
}
#endif
