#if DEBUG
import SwiftUI
import HavenCore

/// The room shapes `GridPacking` is actually about, as whole rooms.
///
/// **Its own file rather than a `TileGallery` page**, which is where this project's other view
/// verification lives. The gallery's fixture store is built per *tile* — one entity per state worth
/// looking at — and these need whole rooms with their own areas, curation tiers and orderings. Bent
/// into that store they would have doubled it and taught the reader less.
private struct RoomGridPreviews: View {
    @State private var store = RoomGridPreviews.populatedStore()
    @State private var navigation = Navigation()
    // The camera tile's image loader reads it for the base URL.
    @State private var app = AppModel()
    let rooms: [RoomSection]
    let configuring: Bool

    /// Seeded drag state, so the mid-gesture appearance can be rendered at all.
    var drag = TileDragState()

    init(only areaIds: [String], configuring: Bool = false, arranged: [String: [String]] = [:],
         sized: [String: TileSpan] = [:], drag: TileDragState = TileDragState()) {
        self.drag = drag
        self.configuring = configuring
        let store = RoomGridPreviews.populatedStore()
        for (areaId, order) in arranged {
            store.config.seedForTesting(store.config.document.settingOrder(order, forRoom: areaId))
        }
        for (entityId, span) in sized {
            store.config.seedForTesting(
                store.config.document.settingSize(span, for: entityId, on: .overview))
        }
        _store = State(initialValue: store)
        rooms = store.rooms().filter { areaIds.contains($0.areaId) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(rooms) { room in RoomSectionView(room: room, drag: drag) }
            }
            .padding()
        }
        .environment(store)
        .environment(navigation)
        .environment(app)
        .onAppear { navigation.isConfiguring = configuring }
    }

    @MainActor
    static func populatedStore() -> HomeStore {
        let store = HomeStore()
        var areas: [ResolvedArea] = []

        func set(_ id: String, _ state: String, _ name: String, _ attrs: [String: JSONValue] = [:]) {
            var a = attrs; a["friendly_name"] = .string(name)
            store.states[id] = EntityState(entityId: id, state: state, attributes: a,
                                           lastUpdated: Date(timeIntervalSince1970: 0))
        }
        func area(_ id: String, _ name: String, _ ids: [String]) {
            areas.append(ResolvedArea(id: id, name: name, entityIds: ids,
                                      tiers: Dictionary(uniqueKeysWithValues: ids.map { ($0, .primary) })))
        }

        // All 1×1s, five of them: fills a row and wraps.
        for i in 1...5 { set("light.a\(i)", i.isMultiple(of: 2) ? "off" : "on", "Lamp \(i)") }
        area("ones", "All 1×1", (1...5).map { "light.a\($0)" })

        // One thermostat then lights: the gap-filling case — the lights now sit beside it where the
        // old band boundary left two columns empty.
        set("climate.b", "heat", "Thermostat",
            ["temperature": .double(21), "hvac_action": .string("heating"),
             "hvac_modes": .array([.string("off"), .string("heat")])])
        for i in 1...3 { set("light.b\(i)", "on", "Lamp \(i)") }
        // **Power, not temperature.** A temperature sensor is uplifted into the room's environment
        // chips and never reaches the grid, so it cannot show what a wide sensor does to a row.
        set("sensor.b_temp", "63", "Power", ["device_class": .string("power"),
                                             "unit_of_measurement": .string("W")])
        area("gap", "Thermostat then lights",
             ["climate.b"] + (1...3).map { "light.b\($0)" } + ["sensor.b_temp"])

        // Two cameras: 2×2s side by side, then a light that must go *below* them, not beside.
        set("camera.c1", "recording", "Front Door")
        set("camera.c2", "recording", "Driveway")
        set("light.c", "on", "Porch")
        area("cams", "Two cameras", ["camera.c1", "camera.c2", "light.c"])

        // All 2-wide: a thermostat and two media players.
        set("climate.d", "cool", "Thermostat",
            ["temperature": .double(19), "hvac_action": .string("cooling"),
             "hvac_modes": .array([.string("off"), .string("cool")])])
        set("media_player.d1", "playing", "Speaker", ["media_title": .string("A Song")])
        set("media_player.d2", "idle", "TV")
        // A temperature and a humidity reading, so the room's environment chips exist — the block
        // the edit control has to sit to the left of. Without them the toolbar renders one item and
        // says nothing about ordering, which is the whole question.
        set("sensor.d_temp", "21.4", "Temperature",
            ["device_class": .string("temperature"), "unit_of_measurement": .string("°C")])
        set("sensor.d_hum", "44", "Humidity",
            ["device_class": .string("humidity"), "unit_of_measurement": .string("%")])
        area("wide", "All 2-wide", ["climate.d", "media_player.d1", "media_player.d2",
                                    "sensor.d_temp", "sensor.d_hum"])

        store.home = ResolvedHome(floors: [ResolvedFloor(id: "f", name: "Ground", level: 0, areas: areas)])
        store.resolveEnvironment()
        let origin = Date(timeIntervalSince1970: 0)
        let points = [20.8, 20.9, 21.2, 21.6, 21.4, 21.1, 20.9, 21.0, 21.3, 21.5, 21.4, 21.4]
            .enumerated().map {
                HistoryPoint(time: origin.addingTimeInterval(Double($0.offset) * 3600), value: $0.element)
            }
        store.historyCache.byKey[HomeStore.historyKey("sensor.b_temp", .day, nil)] =
            (HistorySeries(points: points), origin)
        return store
    }
}

/// **Room detail, which is a different set of sizes for the same rooms.** Media and cameras go
/// full-bleed here where the dashboard gives them half a row, and this is what checks that the one
/// dispatcher draws both — the groups used to be three hand-built stacks precisely because a
/// `LazyVGrid` could not express a 4×2.
private struct RoomDetailPreviewHost: View {
    @State private var store = RoomGridPreviews.populatedStore()
    @State private var navigation = Navigation()
    @State private var app = AppModel()
    let areaId: String
    /// Whether this household may configure. **Not incidental to the preview**: the edit control is
    /// omitted rather than disabled for anyone who cannot write, so a fixture that does not say so
    /// renders a toolbar with the control missing and looks exactly like the bug of it never having
    /// been added.
    var configurable = false

    var body: some View {
        NavigationStack {
            if let room = store.rooms().first(where: { $0.areaId == areaId }) {
                RoomDetailView(room: room)
            }
        }
        .environment(store)
        .environment(navigation)
        .environment(app)
        .onAppear {
            if configurable {
                store.config.setForTesting(isAdmin: true, isLoaded: true,
                                           isWritable: true, isConnected: true)
            }
        }
    }
}

#Preview("Room grid — a wide sensor") {
    RoomGridPreviews(only: ["gap"], sized: ["sensor.b_temp": TileSpan(columns: 2, rows: 1)])
}

/// **The room-level edit control**, which is how a room gets arranged at all — and the only way to
/// reach the devices curation keeps off the dashboard, since a demoted sensor lives nowhere else.
#Preview("Room detail — configurable") {
    RoomDetailPreviewHost(areaId: "wide", configurable: true)
}

/// A camera group at full width, with a light beside it in its own group — two spans, one builder.
#Preview("Room detail — cameras") { RoomDetailPreviewHost(areaId: "cams") }

/// Climate at half a row and two media players at full width, which is the pair that used to need
/// two different `[GridItem]` arrays and a bespoke stack.
#Preview("Room detail — climate and media") { RoomDetailPreviewHost(areaId: "wide") }

/// Four across, then a wrap.
#Preview("Room grid — all 1×1") { RoomGridPreviews(only: ["ones"]) }

/// **The gap-filling case.** A lone thermostat used to leave the rest of its band empty because the
/// next band started fresh; now the lights beside it fill the row.
#Preview("Room grid — thermostat then lights") { RoomGridPreviews(only: ["gap"]) }

/// A 2×2 holds its columns across two rows, and the second camera cannot fit beside the first, so it
/// starts a new row — leaving column 3 empty rather than reaching forward for something that fits.
#Preview("Room grid — two cameras") { RoomGridPreviews(only: ["cams"]) }

/// Every tile 2-wide, which is also where the row height comes from: a media tile wants more than a
/// light does, and the row is measured from the tallest single-row tile in the room.
#Preview("Room grid — all 2-wide") { RoomGridPreviews(only: ["wide"]) }

/// Configuration mode: placeholders must occupy exactly the cells their tiles do, and the `+` is a
/// 1×1 at the end of the sequence rather than a special case in whichever grid used to exist.
#Preview("Room grid — configuring") { RoomGridPreviews(only: ["gap", "cams"], configuring: true) }

/// **Mid-drag**, which no gesture in a preview can produce: `light.b1` has been lifted — its slot
/// left behind as a dashed hole rather than closing up — and the caret on `light.b3`'s leading edge
/// marks the seam it would drop into.
///
/// `entered()` is what a drop delegate calls when the finger arrives over a tile, and seeding it is
/// not ceremony: the slot and the caret are drawn only while a drag is demonstrably live, so a state
/// that merely names a dragged tile now — correctly — renders nothing at all.
#Preview("Room grid — mid-drag") {
    let drag = TileDragState()
    drag.dragging = "light.b1"
    drag.target = "light.b3"
    drag.entered()
    return RoomGridPreviews(only: ["gap"], configuring: true, drag: drag)
}

/// **The room-level edit control**, which is how a room gets arranged at all — and the only way to
/// reach the devices curation keeps off the dashboard, since a demoted sensor lives nowhere else.
#Preview("Room detail — configurable") {
    RoomDetailPreviewHost(areaId: "wide", configurable: true)
}

/// A camera group at full width, with a light beside it in its own group — two spans, one builder.
#Preview("Room detail — cameras") { RoomDetailPreviewHost(areaId: "cams") }

/// Climate at half a row and two media players at full width, which is the pair that used to need
/// two different `[GridItem]` arrays and a bespoke stack.
#Preview("Room detail — climate and media") { RoomDetailPreviewHost(areaId: "wide") }

/// Four across, then a wrap.
#Preview("Room grid — all 1×1") { RoomGridPreviews(only: ["ones"]) }

/// **The gap-filling case.** A lone thermostat used to leave the rest of its band empty because the
/// next band started fresh; now the lights beside it fill the row.
#Preview("Room grid — thermostat then lights") { RoomGridPreviews(only: ["gap"]) }

/// A 2×2 holds its columns across two rows, and the second camera cannot fit beside the first, so it
/// starts a new row — leaving column 3 empty rather than reaching forward for something that fits.
#Preview("Room grid — two cameras") { RoomGridPreviews(only: ["cams"]) }

/// Every tile 2-wide, which is also where the row height comes from: a media tile wants more than a
/// light does, and the row is measured from the tallest single-row tile in the room.
#Preview("Room grid — all 2-wide") { RoomGridPreviews(only: ["wide"]) }

/// Configuration mode: placeholders must occupy exactly the cells their tiles do, and the `+` is a
/// 1×1 at the end of the sequence rather than a special case in whichever grid used to exist.
#Preview("Room grid — configuring") { RoomGridPreviews(only: ["gap", "cams"], configuring: true) }

/// **Mid-drag**, which no gesture in a preview can produce: `light.b1` has been lifted — its slot
/// left behind as a dashed hole rather than closing up — and the caret on `light.b3`'s leading edge
/// marks the seam it would drop into.
///
/// `entered()` is what a drop delegate calls when the finger arrives over a tile, and seeding it is
/// not ceremony: the slot and the caret are drawn only while a drag is demonstrably live, so a state
/// that merely names a dragged tile now — correctly — renders nothing at all.
#Preview("Room grid — mid-drag") {
    let drag = TileDragState()
    drag.dragging = "light.b1"
    drag.target = "light.b3"
    drag.entered()
    return RoomGridPreviews(only: ["gap"], configuring: true, drag: drag)
}

/// **A wide sensor beside 1×1 tiles**, which is the case that decides whether a tile's *measured*
/// size and its *drawn* size agree. `RoomGrid` takes its row height from the tallest single-row tile,
/// and a 2×1 sensor is single-row — so anything inside it that reports a large ideal height silently
/// makes every row in the room that tall.
/// **An arranged room.** A drag cannot be exercised by a preview, so what is rendered is its
/// *result*: a stored order that is plainly not the default — the thermostat pushed to the end,
/// behind lights it would normally lead. If ordering were being ignored this would look identical to
/// the preview above it.
#Preview("Room grid — arranged") {
    RoomGridPreviews(only: ["gap"],
                     arranged: ["gap": ["light.b3", "light.b1", "climate.b", "light.b2"]])
}
#endif
