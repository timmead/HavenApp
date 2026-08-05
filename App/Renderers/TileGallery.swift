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
    enum Page { case first, second, third, fourth, fifth, sixth, seventh, eighth }
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
                            Divider()
                            // **The second step**, which is otherwise only reachable by tapping a
                            // cover — and an unrendered state is one nobody has looked at.
                            AddTileView(areaId: "lounge", surface: .overview,
                                        choosingTypeForPreview: "cover.open")
                        }
                    }
                    // The two configuration sheets have no other verification, which is the same
                    // argument this file makes about the tiles. Rendered side by side rather than
                    // only next to their own views, so the pair is reviewed as a pair.
                case .sixth:
                    stateStyles
                case .seventh:
                    climateLarge
                case .eighth:
                    deviceContext
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
    /// — an open door against a closed one, a filled power symbol against a hollow one — which is
    /// what makes the icon style worth having; the label style exists for the device classes where a
    /// picture is a guess.
    ///
    /// The unreachable cases are here deliberately. Both styles must say "Unavailable" rather than
    /// asserting a state, and the lock is the one where getting that wrong is a security claim.
    private var stateStyles: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Icon — light, binary sensor, lock, cover, switch") {
                LazyVGrid(columns: Self.columns, spacing: 10) {
                    ForEach(Self.twoStateCases, id: \.self) { id in
                        DeviceTileView(entityId: id, surface: .overview)
                    }
                }
            }
            section("Label — the same devices, same states") {
                LazyVGrid(columns: Self.columns, spacing: 10) {
                    ForEach(Self.twoStateCases.map { $0 + "_l" }, id: \.self) { id in
                        DeviceTileView(entityId: id, surface: .overview)
                    }
                }
            }
        }
    }

    /// **Typed and hoisted out of the view builder deliberately.** As inline literals inside
    /// `ForEach` these two lists compiled fine in a normal build and defeated the *preview*
    /// compiler — "unable to type-check this expression in reasonable time" — which would have made
    /// the one page that verifies this feature the one page nobody could look at.
    ///
    /// The label row is these same ids with a suffix, so the two rows cannot drift apart: a case
    /// added to one is added to both.
    /// The three derived-state garages. **A named type rather than an array of tuples**, because as
    /// a literal inside the fixture builder this defeated the *preview* compiler — "unable to
    /// type-check this expression in reasonable time" — while compiling fine in a normal build. The
    /// same trap `twoStateCases` records below.
    struct GarageFixture { let id: String; let name: String; let closed: String; let open: String }
    private static let garages: [GarageFixture] = [
        GarageFixture(id: "cover.limit_closed", name: "Garage A", closed: "on", open: "off"),
        GarageFixture(id: "cover.partly", name: "Garage B", closed: "off", open: "off"),
        GarageFixture(id: "cover.limit_open", name: "Garage C", closed: "off", open: "on"),
    ]

    private static let twoStateCases: [String] = [
        "light.on", "light.off",
        "binary_sensor.active", "binary_sensor.clear",
        "lock.locked", "lock.unlocked", "lock.jammed",
        "cover.open", "cover.closed",
        "switch.on", "switch.off",
        "binary_sensor.unavailable", "lock.unavailable", "switch.unavailable",
        "cover.unavailable", "light.unavailable",
    ]

    /// **What else a device knows**, in the three shapes that decide whether the card is honest.
    ///
    /// The no-companion case is the important one: it must draw *nothing at all*, because every
    /// device in a home without a registry `device_id` is that case and none of them should grow an
    /// empty card. The unreachable reading is the second: an offline sensor and an absent one must
    /// not look the same.
    private var deviceContext: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("No companions, nothing derived — both cards draw nothing") {
                VStack(spacing: 10) {
                    DeviceStateCard(entityId: "light.on")
                    DeviceContextCard(entityId: "light.on")
                }
            }
            // What the peek modal now shows for a composite: the state Haven works out, and the
            // sensors it came from.
            section("Computed state, and what it came from") {
                VStack(spacing: 10) {
                    DeviceStateCard(entityId: "switch.opener")
                    DeviceStateCard(entityId: "cover.partly")
                    DeviceStateCard(entityId: "cover.open_only")
                }
            }
            section("A lock, and whether the door is actually shut") {
                DeviceContextCard(entityId: "lock.locked")
            }
            section("Several, including one unreachable") {
                DeviceContextCard(entityId: "cover.open")
            }
            // **The state a cover entity has no word for.** `cover.partly` reports "open" like any
            // other; its two bound limit sensors both reading off is the only way to know the door
            // is stopped half way.
            section("Derived from bound limits — including one sensor only") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 2),
                          spacing: 9) {
                    ForEach(["cover.limit_closed", "cover.partly", "cover.limit_open",
                             "switch.opener", "cover.open_only",
                             "cover.closed_only"], id: \.self) { id in
                        DeviceTileView(entityId: id, surface: .overview)
                    }
                }
            }
        }
    }

    /// **The 4×2 climate tile, at the height a room actually gives it.**
    ///
    /// 173pt — two `RoomGrid` rows plus the spacing between them — rather than whatever a `VStack`
    /// would hand it. That distinction is the entire reason this section exists: a tile that looks
    /// right at its natural height and overflows at its real one is a tile nobody has verified.
    private var climateLarge: some View {
        section("Climate — 4×2, at a room's row height") {
            VStack(spacing: 10) {
                ForEach(["climate.heating", "climate.off", "climate.unavailable"], id: \.self) { id in
                    ClimateTile(entityId: id, size: .large)
                        .frame(height: 173)
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
            "current_temperature": .double(20.4),
                                        "fan_mode": .string("auto"), "hvac_action": .string("heating"),
                                        "hvac_modes": .array([.string("off"), .string("heat")])])
        set("climate.cooling", "cool", ["friendly_name": .string("Study"), "temperature": .double(19),
            "current_temperature": .double(22.1),
                                        "fan_mode": .string("auto"), "hvac_action": .string("cooling"),
                                        "hvac_modes": .array([.string("off"), .string("cool")])])
        set("climate.drying", "dry", ["friendly_name": .string("Cellar"), "temperature": .double(20),
            "current_temperature": .double(19.6),
                                      "hvac_action": .string("drying"),
                                      "hvac_modes": .array([.string("off"), .string("dry")])])
        set("climate.fan", "fan_only", ["friendly_name": .string("Porch"), "temperature": .double(22),
            "current_temperature": .double(20.8),
                                        "fan_mode": .string("high"), "hvac_action": .string("fan"),
                                        "hvac_modes": .array([.string("off"), .string("fan_only")])])
        // On and at target: the pair with `climate.heating` that the fill rule is about.
        set("climate.idle", "heat", ["friendly_name": .string("Hall"), "temperature": .double(21),
            "current_temperature": .double(20.4),
                                     "fan_mode": .string("auto"), "hvac_action": .string("idle"),
                                     "hvac_modes": .array([.string("off"), .string("heat")])])
        set("climate.off", "off", ["friendly_name": .string("Attic"), "temperature": .double(18),
            "current_temperature": .double(20.8),
                                   "hvac_modes": .array([.string("off"), .string("heat")])])
        set("climate.unknown", "unknown", ["friendly_name": .string("Garage"), "temperature": .double(19),
            "current_temperature": .double(22.1),
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
        // Companion fixtures: entities that share a device_id with a primary and sit at
        // `.companion`, which is what `CompositeState` joins on. Without registry info the resolver
        // correctly finds nothing, and the card would render blank while proving nothing.
        set("binary_sensor.front_contact", "off", ["friendly_name": .string("Door Contact"),
                                                   "device_class": .string("door")])
        set("sensor.front_battery", "88", ["friendly_name": .string("Battery"),
                                           "device_class": .string("battery"),
                                           "unit_of_measurement": .string("%")])
        set("binary_sensor.garage_fully_closed", "on", ["friendly_name": .string("Fully Closed"),
                                                        "device_class": .string("door")])
        set("binary_sensor.garage_fully_open", "unavailable", ["friendly_name": .string("Fully Open"),
                                                               "device_class": .string("door")])
        set("sensor.garage_signal", "-61", ["friendly_name": .string("Signal"),
                                            "unit_of_measurement": .string("dBm")])
        // A relay opener: a *switch* in Home Assistant whose own state says a contact closed, not
        // where the door is. Its limits are the only thing that knows.
        set("switch.opener", "off", ["friendly_name": .string("Garage D")])
        // One limit only, in both directions: half the information is not none of it.
        set("cover.open_only", "open", ["friendly_name": .string("Open only"),
                                        "device_class": .string("garage")])
        set("binary_sensor.open_only_open", "off", ["friendly_name": .string("Fully Open"),
                                                    "device_class": .string("door")])
        set("cover.closed_only", "open", ["friendly_name": .string("Closed only"),
                                          "device_class": .string("garage")])
        set("binary_sensor.closed_only_closed", "off", ["friendly_name": .string("Fully Closed"),
                                                        "device_class": .string("door")])
        set("binary_sensor.opener_closed", "off", ["friendly_name": .string("Fully Closed"),
                                                   "device_class": .string("door")])
        set("binary_sensor.opener_open", "off", ["friendly_name": .string("Fully Open"),
                                                 "device_class": .string("door")])
        // Three garages, all reporting "open" from the cover entity itself — the limits are what
        // tell them apart, which is the point.
        for garage in Self.garages {
            let (id, name, closed, open) = (garage.id, garage.name, garage.closed, garage.open)
            set(id, "open", ["friendly_name": .string(name), "device_class": .string("garage")])
            set("binary_sensor.\(id.split(separator: ".")[1])_closed", closed,
                ["friendly_name": .string("Fully Closed"), "device_class": .string("door")])
            set("binary_sensor.\(id.split(separator: ".")[1])_open", open,
                ["friendly_name": .string("Fully Open"), "device_class": .string("door")])
        }
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
            // The composite fixtures. `.companion` is the tier `EntityCuration`'s container rule
            // produces and that no surface rendered until `DeviceContextCard`.
            ResolvedArea(id: "doors", name: "Doors",
                         entityIds: ["lock.locked", "binary_sensor.front_contact",
                                     "sensor.front_battery", "cover.open",
                                     "binary_sensor.garage_fully_closed",
                                     "binary_sensor.garage_fully_open", "sensor.garage_signal"],
                         tiers: ["lock.locked": .primary,
                                 "binary_sensor.front_contact": .companion,
                                 "sensor.front_battery": .companion,
                                 "cover.open": .primary,
                                 "binary_sensor.garage_fully_closed": .companion,
                                 "binary_sensor.garage_fully_open": .companion,
                                 "sensor.garage_signal": .companion]),
        ])],
        // Two devices: the front door's lock with its contact and battery, and the garage cover
        // with its two limit sensors and a signal reading. `light.on` deliberately has no device at
        // all, which is the case that must render nothing.
        registryInfo: [
            "lock.locked": EntityRegistryInfo(platform: nil, uniqueId: nil, deviceId: "front-door"),
            "binary_sensor.front_contact": EntityRegistryInfo(platform: nil, uniqueId: nil, deviceId: "front-door"),
            "sensor.front_battery": EntityRegistryInfo(platform: nil, uniqueId: nil, deviceId: "front-door"),
            "cover.open": EntityRegistryInfo(platform: nil, uniqueId: nil, deviceId: "garage"),
            "binary_sensor.garage_fully_closed": EntityRegistryInfo(platform: nil, uniqueId: nil, deviceId: "garage"),
            "binary_sensor.garage_fully_open": EntityRegistryInfo(platform: nil, uniqueId: nil, deviceId: "garage"),
            "sensor.garage_signal": EntityRegistryInfo(platform: nil, uniqueId: nil, deviceId: "garage"),
        ])
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
            ("switch.on_l", "on", "Fan", nil),
            ("switch.off_l", "off", "Heater", "outlet"),
            ("switch.unavailable_l", "unavailable", "Pump", nil),
            ("cover.unavailable_l", "unavailable", "Awning", nil),
            ("light.on_l", "on", "Kitchen", nil),
            ("light.off_l", "off", "Hallway", nil),
            ("light.unavailable_l", "unavailable", "Porch", nil),
        ] as [(String, String, String, String?)] {
            var attrs: [String: JSONValue] = ["friendly_name": .string(name)]
            if let dc { attrs["device_class"] = .string(dc) }
            store.states[id] = EntityState(entityId: id, state: state, attributes: attrs,
                                           lastUpdated: Date(timeIntervalSince1970: 0))
            document = document.settingStateStyle(.label, for: id)
        }
        // Each garage is a *device* of type `garage_door` whose primary is the cover — which is
        // what choosing that type in the `+` flow creates — with its limits as inputs.
        for garage in Self.garages {
            let stem = String(garage.id.split(separator: ".")[1])
            document = document.settingDevice(
                DashboardDocument.StoredDevice(
                    id: garage.id, type: "garage_door", areaId: "lounge",
                    inputs: [.primary: [garage.id],
                             .closedLimit: ["binary_sensor.\(stem)_closed"],
                             .openLimit: ["binary_sensor.\(stem)_open"]]),
                id: garage.id)
        }
        document = document.settingDevice(
            DashboardDocument.StoredDevice(
                id: "switch.opener", type: "garage_door", areaId: "lounge",
                inputs: [.primary: ["switch.opener"],
                         .closedLimit: ["binary_sensor.opener_closed"],
                         .openLimit: ["binary_sensor.opener_open"]]),
            id: "switch.opener")
        for (id, role, sensor) in [("cover.open_only", DeviceRole.openLimit, "binary_sensor.open_only_open"),
                                   ("cover.closed_only", DeviceRole.closedLimit, "binary_sensor.closed_only_closed")] {
            document = document.settingDevice(
                DashboardDocument.StoredDevice(id: id, type: "garage_door", areaId: "lounge",
                                               inputs: [.primary: [id], role: [sensor]]),
                id: id)
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

#Preview("Tiles 7 — climate 4×2") {
    TileGallery(page: .seventh)
}

#Preview("Tiles 8 — what else a device knows") {
    TileGallery(page: .eighth)
}
#endif
