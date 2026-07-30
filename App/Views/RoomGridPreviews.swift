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

    init(only areaIds: [String], configuring: Bool = false, arranged: [String: [String]] = [:]) {
        self.configuring = configuring
        let store = RoomGridPreviews.populatedStore()
        for (areaId, order) in arranged {
            store.config.seedForTesting(store.config.document.settingOrder(order, forRoom: areaId))
        }
        _store = State(initialValue: store)
        rooms = store.rooms().filter { areaIds.contains($0.areaId) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(rooms) { room in RoomSectionView(room: room) }
            }
            .padding()
        }
        .environment(store)
        .environment(navigation)
        .environment(app)
        .onAppear { navigation.isConfiguring = configuring }
    }

    @MainActor
    private static func populatedStore() -> HomeStore {
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
        area("gap", "Thermostat then lights", ["climate.b"] + (1...3).map { "light.b\($0)" })

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
        area("wide", "All 2-wide", ["climate.d", "media_player.d1", "media_player.d2"])

        store.home = ResolvedHome(floors: [ResolvedFloor(id: "f", name: "Ground", level: 0, areas: areas)])
        return store
    }
}

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

/// **An arranged room.** A drag cannot be exercised by a preview, so what is rendered is its
/// *result*: a stored order that is plainly not the default — the thermostat pushed to the end,
/// behind lights it would normally lead. If ordering were being ignored this would look identical to
/// the preview above it.
#Preview("Room grid — arranged") {
    RoomGridPreviews(only: ["gap"],
                     arranged: ["gap": ["light.b3", "light.b1", "climate.b", "light.b2"]])
}
#endif
