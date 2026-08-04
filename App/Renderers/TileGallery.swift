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
/// Split into pages because a preview snapshot captures one screen, not a scroll view's full
/// content — a single gallery would leave half the tiles unverified below the fold, which is
/// precisely the "assumed rather than looked at" this exists to end. It went from two pages to
/// three when climate grew to eight fixtures at double width and pushed its own `unknown` and
/// `unavailable` cases off the bottom of page one: a page that overflows has quietly stopped being
/// a baseline, so the fix is another page rather than a shorter list.
struct TileGallery: View {
    enum Page { case first, second, third, fourth, fifth, sixth }
    let page: Page

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
                switch page {
                case .first:
                    section("Light") { ids("light", ["on", "off", "unavailable"]) }
                    section("Switch") { ids("switch", ["on", "off", "unavailable"]) }
                    section("Cover") { ids("cover", ["open", "closed", "unavailable"]) }
                    // Four, not three: `unavailable` must render `questionmark.circle` and **not**
                    // either padlock glyph — the one place in the tiles where the *symbol*, not
                    // just its colour, is a state claim. See `LockTile`.
                    section("Lock") { ids("lock", ["locked", "unlocked", "jammed", "unavailable"]) }
                    // Four, and the first two are the point: `heat`-and-heating is filled,
                    // `heat`-and-idle is not, and they are otherwise the same tile. The fill now
                    // tracks `hvac_action` rather than on/off (see `ClimateState.isConditioning`),
                    // which is a distinction you can only check by looking at the two side by side.
                    // The unavailable case is the most prominent state claim on any tile: a
                    // thermostat's target temperature is read straight from a cached attribute, so
                    // an unreachable one has a number to show whether or not it means anything.
                    // `unknown` is the fifth for the same reason the lock row has four: it is dimmed
                    // and struck like `unavailable`, but its power button is *live*, because an
                    // unknown thermostat is reachable and a tap is what resolves it. Two tiles that
                    // look alike and behave differently is precisely a thing to look at rather than
                    // infer.
                case .second:
                    section("Scene") { ids("scene", ["idle", "unavailable"]) }
                    // The tile the original sweep actually missed.
                    section("Sensor") { ids("sensor", ["value", "unavailable"]) }
                    section("Binary sensor") { ids("binary_sensor", ["active", "clear", "unavailable"]) }
                    section("Generic") { ids("generic", ["idle", "unavailable"]) }
                    section("Media player — 1×1") { ids("media_player", ["playing", "idle", "unavailable"]) }
                    sensorWide
                    mediaWide
                case .fourth:
                    section("Room configuration — candidates, and none") {
                        VStack(alignment: .leading, spacing: 16) {
                            RoomConfigView(areaId: "lounge")
                            Divider()
                            RoomConfigView(areaId: "hall")
                        }
                    }
                case .fifth:
                    section("Add a device") {
                        VStack(alignment: .leading, spacing: 14) {
                            LazyVGrid(columns: Self.columns, spacing: 10) {
                                DeviceTileView(entityId: "light.on", surface: .overview)
                                AddTilePlaceholder { }
                            }
                            Divider()
                            AddTileView(areaId: "lounge", surface: .overview)
                        }
                    }
                    // The two configuration sheets have no other verification, which is the same
                    // argument this file makes about the tiles. Rendered side by side rather than
                    // only next to their own views, so the pair is reviewed as a pair.
                case .sixth:
                    stateStyles
                case .third:
                    // **Two columns, because that is the only width this tile is ever drawn at.**
                    // Both surfaces hoist climate into a 2-column grid of its own
                    // (`RoomSectionView`, `RoomDetailView`), so rendering it here through the
                    // 4-column `ids(...)` was the gallery lying about the one thing it exists to
                    // show. It cost something real: judgements about what fits beside the target
                    // temperature were made against half the width the tile actually has.
                    section("Climate") { climateRow }
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
                DeviceTileView(entityId: "\(domain).\(name)", surface: .overview)
            }
        }
    }

    /// **The two ways a two-state tile can show itself**, side by side, because the choice between
    /// them is a household setting and neither is obviously right. The glyphs differ between states
    /// — an open door against a closed one — which is what makes the icon style worth having; the
    /// label style exists for the device classes where a picture is a guess.
    ///
    /// The unreachable cases are here deliberately. Both styles must say "Unavailable" rather than
    /// asserting a state, and the lock is the one where getting that wrong is a security claim.
    private var stateStyles: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Icon — binary sensor, lock, cover") {
                LazyVGrid(columns: Self.columns, spacing: 10) {
                    ForEach(["binary_sensor.active", "binary_sensor.clear",
                             "lock.locked", "lock.unlocked", "lock.jammed",
                             "cover.open", "cover.closed",
                             "binary_sensor.unavailable", "lock.unavailable"], id: \.self) { id in
                        DeviceTileView(entityId: id, surface: .overview)
                    }
                }
            }
            section("Label — the same devices, same states") {
                LazyVGrid(columns: Self.columns, spacing: 10) {
                    ForEach(["binary_sensor.active_l", "binary_sensor.clear_l",
                             "lock.locked_l", "lock.unlocked_l", "lock.jammed_l",
                             "cover.open_l", "cover.closed_l",
                             "binary_sensor.unavailable_l", "lock.unavailable_l"], id: \.self) { id in
                        DeviceTileView(entityId: id, surface: .overview)
                    }
                }
            }
        }
    }

    /// Climate at its real width: 2 of 4 columns, as both surfaces draw it.
    private var climateRow: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 2), spacing: 9) {
            ForEach(["heating", "cooling", "drying", "fan", "idle", "off", "unknown", "unavailable"], id: \.self) { name in
                DeviceTileView(entityId: "climate.\(name)", surface: .overview)
            }
        }
    }

    /// The 2×1 sensor, in the three states that decide whether it draws a line at all.
    ///
    /// **The empty and flat cases are the point.** A sparkline with nothing behind it must render as
    /// a plain reading rather than as an axis-less chart of one point, and that is invisible in the
    /// happy case — which is exactly the kind of thing this gallery exists to make visible.
    private var sensorWide: some View {
        section("Sensor — 2×1") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 2), spacing: 9) {
                SensorTile(entityId: "sensor.value", size: .wide)
                SensorTile(entityId: "sensor.spiky", size: .wide)
                SensorTile(entityId: "sensor.nohistory", size: .wide)
                SensorTile(entityId: "sensor.text", size: .wide)
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

        // One fixture per `hvac_action` the tile colours, plus the three states that have no
        // action to colour by. Same mode and target where they can be, so the only difference on
        // screen is the one being checked.
        set("climate.heating", "heat", ["friendly_name": .string("Lounge"), "temperature": .double(21),
                                        "fan_mode": .string("auto"), "hvac_action": .string("heating"),
                                        "hvac_modes": .array([.string("off"), .string("heat")])])
        set("climate.cooling", "cool", ["friendly_name": .string("Study"), "temperature": .double(19),
                                        "fan_mode": .string("auto"), "hvac_action": .string("cooling"),
                                        "hvac_modes": .array([.string("off"), .string("cool")])])
        set("climate.drying", "dry", ["friendly_name": .string("Cellar"), "temperature": .double(20),
                                      "hvac_action": .string("drying"),
                                      "hvac_modes": .array([.string("off"), .string("dry")])])
        set("climate.fan", "fan_only", ["friendly_name": .string("Porch"), "temperature": .double(22),
                                        "fan_mode": .string("high"), "hvac_action": .string("fan"),
                                        "hvac_modes": .array([.string("off"), .string("fan_only")])])
        // On and at target: the pair with `climate.heating` that the fill rule is about.
        set("climate.idle", "heat", ["friendly_name": .string("Hall"), "temperature": .double(21),
                                     "fan_mode": .string("auto"), "hvac_action": .string("idle"),
                                     "hvac_modes": .array([.string("off"), .string("heat")])])
        set("climate.off", "off", ["friendly_name": .string("Attic"), "temperature": .double(18),
                                   "hvac_modes": .array([.string("off"), .string("heat")])])
        set("climate.unknown", "unknown", ["friendly_name": .string("Garage"), "temperature": .double(19),
                                           "hvac_modes": .array([.string("off"), .string("heat")])])
        set("climate.unavailable", "unavailable", ["friendly_name": .string("Loft"),
                                                   "temperature": .double(23)])

        // For the configuration page: two temperature sources called almost the same thing, which
        // is what the entity id on every picker row is for, plus a room with nothing to pick.
        set("sensor.lounge_temp", "21.5", ["friendly_name": .string("Lounge Temperature"),
                                           "device_class": .string("temperature"),
                                           "unit_of_measurement": .string("°C")])
        set("sensor.lounge_temp_window", "20.9", ["friendly_name": .string("Temperature"),
                                                  "device_class": .string("temperature"),
                                                  "unit_of_measurement": .string("%")])
        set("sensor.lounge_hum", "44", ["friendly_name": .string("Lounge Humidity"),
                                        "device_class": .string("humidity"),
                                        "unit_of_measurement": .string("%")])
        set("sensor.lounge_hum_2", "46", ["friendly_name": .string("Lounge Humidity (window)"),
                                          "device_class": .string("humidity"),
                                          "unit_of_measurement": .string("%")])

        set("scene.idle", "scening", ["friendly_name": .string("Movie")])
        set("scene.unavailable", "unavailable", ["friendly_name": .string("Away")])

        set("sensor.spiky", "63", ["friendly_name": .string("Power"),
                                   "device_class": .string("power"),
                                   "unit_of_measurement": .string("W")])
        set("sensor.nohistory", "18.2", ["friendly_name": .string("Shed"),
                                         "device_class": .string("temperature"),
                                         "unit_of_measurement": .string("°C")])
        // A sensor whose state is a word. It is offered the 2×1 like every other sensor — the option
        // set is a fact about the device type, not about today's reading — and it simply has no line.
        set("sensor.text", "Away", ["friendly_name": .string("Mode")])
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
        store.home = ResolvedHome(floors: [ResolvedFloor(id: "f", name: "Ground", level: 0, areas: [
            // Tiers spelled out rather than left to `tier(of:)`'s `.primary` fallback: a sensor is
            // `.secondary` in a real home (see `EntityCuration`), and with everything `.primary` the
            // dashboard would already be showing it all — leaving the add-a-device picker with
            // nothing to offer, which is exactly what the first render of this page showed.
            ResolvedArea(id: "lounge", name: "Lounge",
                         entityIds: ["sensor.lounge_temp", "sensor.lounge_temp_window",
                                     "sensor.lounge_hum", "sensor.lounge_hum_2"],
                         tiers: ["sensor.lounge_temp": .secondary,
                                 "sensor.lounge_temp_window": .secondary,
                                 "sensor.lounge_hum": .secondary,
                                 "sensor.lounge_hum_2": .secondary]),
            ResolvedArea(id: "hall", name: "Hall", entityIds: [], tiers: [:]),
        ])])
        store.resolveEnvironment()
        // The label-style twins: the same states again, with the household's choice stored, so both
        // styles can be compared rather than described.
        var document = store.config.document
        for (id, state, name, dc) in [
            ("binary_sensor.active_l", "on", "Door", "door"),
            ("binary_sensor.clear_l", "off", "Window", "window"),
            ("binary_sensor.unavailable_l", "unavailable", "Motion", "motion"),
            ("lock.locked_l", "locked", "Front", nil),
            ("lock.unlocked_l", "unlocked", "Back", nil),
            ("lock.jammed_l", "jammed", "Side", nil),
            ("lock.unavailable_l", "unavailable", "Shed", nil),
            ("cover.open_l", "open", "Blinds", nil),
            ("cover.closed_l", "closed", "Garage", "garage"),
        ] as [(String, String, String, String?)] {
            var attrs: [String: JSONValue] = ["friendly_name": .string(name)]
            if let dc { attrs["device_class"] = .string(dc) }
            store.states[id] = EntityState(entityId: id, state: state, attributes: attrs,
                                           lastUpdated: Date(timeIntervalSince1970: 0))
            document = document.settingStateStyle(.label, for: id)
        }
        store.config.seedForTesting(document)

        // Seeded history, so the sparkline can be looked at without a server. A gentle curve and a
        // spiky one, because the two are what the y-domain choice is about: a room that moved half a
        // degree all day must still show its shape rather than a flat line against a zero baseline.
        let origin = Date(timeIntervalSince1970: 0)
        func seed(_ id: String, _ values: [Double]) {
            let points = values.enumerated().map {
                HistoryPoint(time: origin.addingTimeInterval(Double($0.offset) * 3600), value: $0.element)
            }
            store.historyCache.byKey[HomeStore.historyKey(id, .day, nil)] = (HistorySeries(points: points), origin)
        }
        seed("sensor.value", [20.8, 20.9, 21.2, 21.6, 21.4, 21.1, 20.9, 21.0, 21.3, 21.5, 21.4, 21.4])
        seed("sensor.spiky", [4, 6, 5, 210, 180, 12, 8, 7, 240, 190, 15, 63])
        // `sensor.nohistory` and `sensor.text` are deliberately left unseeded.
        return store
    }
}

#Preview("Tiles 1 — light, switch, cover, lock") {
    TileGallery(page: .first)
}

#Preview("Tiles 2 — scene, sensor, binary, generic, media") {
    TileGallery(page: .second)
}

/// Climate gets a page to itself: eight fixtures at double width is more than fits beside anything
/// else, and every one of them is a distinct colour or state rule.
#Preview("Tiles 3 — climate") {
    TileGallery(page: .third)
}

/// The configuration sheets, which have no other verification.
#Preview("Tiles 4 — configuration") {
    TileGallery(page: .fourth)
}

/// Its own page: page four was already two full sheets, and a page that overflows has stopped being
/// a baseline — the same reason climate's eight fixtures forced a third.
#Preview("Tiles 5 — add a device") {
    TileGallery(page: .fifth)
}

#Preview("Tiles 6 — two-state styles") {
    TileGallery(page: .sixth)
}
#endif
