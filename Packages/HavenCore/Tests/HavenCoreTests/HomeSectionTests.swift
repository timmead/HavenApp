import Testing
@testable import HavenCore

/// The area registry's own `temperature_entity_id`/`humidity_entity_id` still reach the heading —
/// now via `RoomEnvironmentResolver` rather than being read by `SectionBuilder` directly — and the
/// entities they name are shown there *instead of* as tiles.
@Test func buildsRoomsWithUpliftAndDevices() {
    let areas = [AreaRegistryEntry(areaId: "a", name: "Living", floorId: nil, icon: nil,
                                   temperatureEntityId: "sensor.t", humidityEntityId: "sensor.h")]
    let entities = [EntityRegistryEntry(entityId: "light.l", areaId: "a", deviceId: nil, name: nil),
                    EntityRegistryEntry(entityId: "sensor.t", areaId: "a", deviceId: nil, name: nil),
                    EntityRegistryEntry(entityId: "sensor.h", areaId: "a", deviceId: nil, name: nil),
                    EntityRegistryEntry(entityId: "sensor.power", areaId: "a", deviceId: nil, name: nil)]
    let home = RegistryResolver.resolve(floors: [], areas: areas, devices: [], entities: entities)
    let env = RoomEnvironmentResolver.resolve(home: home, sources: [:])
    let rooms = SectionBuilder.rooms(from: home, environment: env, devices: [:], overrides: [:], orders: [:])
    let living = rooms.first { $0.name == "Living" }!
    #expect(living.headerSensors.map(\.entityId).sorted() == ["sensor.h", "sensor.t"])
    // uplifted temp/humidity are NOT tiles; other entities are
    let deviceIds = living.deviceRefs.map(\.id).sorted()
    #expect(deviceIds == ["light.l", "sensor.power"])
}

/// A thermostat sourcing the pills must keep its tile: the heading borrowed one attribute, it did
/// not take over the entity. Without this a thermostat-only room would lose its climate control.
@Test func aThermostatSourcingTheHeadingKeepsItsTile() {
    let areas = [AreaRegistryEntry(areaId: "a", name: "Living", floorId: nil, icon: nil,
                                   temperatureEntityId: nil, humidityEntityId: nil)]
    let entities = [EntityRegistryEntry(entityId: "climate.lr", areaId: "a", deviceId: nil, name: nil)]
    let home = RegistryResolver.resolve(floors: [], areas: areas, devices: [], entities: entities)
    let env = RoomEnvironmentResolver.resolve(
        home: home,
        sources: ["climate.lr": RoomEnvironmentSource(deviceClass: nil, hasCurrentTemperature: true,
                                                      hasCurrentHumidity: true)])
    let living = SectionBuilder.rooms(from: home, environment: env, devices: [:], overrides: [:], orders: [:]).first!
    #expect(living.headerSensors.count == 2)
    #expect(living.deviceRefs.map(\.id) == ["climate.lr"])
}

/// A home with no resolved environment renders no pills, and loses no tiles doing so.
@Test func anEmptyEnvironmentLeavesEveryEntityAsATile() {
    let areas = [AreaRegistryEntry(areaId: "a", name: "Living", floorId: nil, icon: nil,
                                   temperatureEntityId: nil, humidityEntityId: nil)]
    let entities = [EntityRegistryEntry(entityId: "sensor.t", areaId: "a", deviceId: nil, name: nil)]
    let home = RegistryResolver.resolve(floors: [], areas: areas, devices: [], entities: entities)
    let living = SectionBuilder.rooms(from: home, environment: [:], devices: [:], overrides: [:], orders: [:]).first!
    #expect(living.headerSensors.isEmpty)
    #expect(living.deviceRefs.map(\.id) == ["sensor.t"])
}

// MARK: - Surfaces

/// A room with one entity per tier, plus the two user decisions, read from both surfaces.
@Test func aSurfaceShowsItsOwnTiersPlusWhatTheUserPutThere() {
    let area = ResolvedArea(id: "lounge", name: "Lounge",
                            entityIds: ["light.a", "sensor.b", "sensor.batt", "light.hidden"],
                            tiers: ["light.a": .primary, "sensor.b": .secondary,
                                    "sensor.batt": .companion, "light.hidden": .hidden])
    let home = ResolvedHome(floors: [ResolvedFloor(id: "f", name: "F", level: 0, areas: [area])])
    let rooms = SectionBuilder.rooms(from: home, environment: [:], devices: [:], overrides: [
        // Off the dashboard, still in room detail — the case this whole design exists for.
        "light.a": [.overview: .hidden],
        // On the dashboard though curation demoted it.
        "sensor.b": [.overview: .shown],
        // Home Assistant hid this one; a stored override must not resurrect it.
        "light.hidden": [.overview: .shown],
    ], orders: [:])
    let room = rooms[0]

    #expect(room.refs(for: .overview).map(\.id) == ["sensor.b"])
    #expect(room.refs(for: .roomDetail).map(\.id) == ["light.a", "sensor.b"])
}

@Test func withNoOverridesEachSurfaceIsExactlyItsTiers() {
    let area = ResolvedArea(id: "lounge", name: "Lounge",
                            entityIds: ["light.a", "sensor.b", "sensor.batt"],
                            tiers: ["light.a": .primary, "sensor.b": .secondary,
                                    "sensor.batt": .companion])
    let home = ResolvedHome(floors: [ResolvedFloor(id: "f", name: "F", level: 0, areas: [area])])
    let room = SectionBuilder.rooms(from: home, environment: [:], devices: [:], overrides: [:], orders: [:])[0]
    #expect(room.refs(for: .overview).map(\.id) == ["light.a"])
    #expect(room.refs(for: .roomDetail).map(\.id) == ["light.a", "sensor.b"])
}

// MARK: - Per-surface order and its fallback chain (design decision 9)

/// A room with three lights on both surfaces and one demoted sensor that only room detail shows.
/// The sensor is the interesting one: it is what an overview-only order can never mention, and its
/// silent resetting is the defect decision 9 exists to end.
private func arrangeable(_ orders: [HavenSurface: [String]]) -> RoomSection {
    let area = ResolvedArea(id: "lounge", name: "Lounge",
                            entityIds: ["light.a", "light.b", "light.c", "sensor.demoted"],
                            tiers: ["light.a": .primary, "light.b": .primary, "light.c": .primary,
                                    "sensor.demoted": .secondary])
    let home = ResolvedHome(floors: [ResolvedFloor(id: "f", name: "F", level: 0, areas: [area])])
    return SectionBuilder.rooms(from: home, environment: [:], devices: [:], overrides: [:],
                                orders: ["lounge": orders])[0]
}

/// (a) A surface's own list wins over everything, including the other surface's.
@Test func aSurfacesOwnOrderWinsOverTheOthers() {
    let room = arrangeable([.overview: ["light.c", "light.a", "light.b"],
                            .roomDetail: ["light.b", "light.a", "light.c", "sensor.demoted"]])
    #expect(room.refs(for: .overview).map(\.id) == ["light.c", "light.a", "light.b"])
    #expect(room.refs(for: .roomDetail).map(\.id) == ["light.b", "light.a", "light.c", "sensor.demoted"])
}

/// (b) An unarranged surface follows the other surface's list rather than the default order — which
/// is what makes a room arranged on the dashboard look arranged when you open it.
@Test func anUnarrangedSurfaceFollowsTheOtherSurfacesOrder() {
    let room = arrangeable([.overview: ["light.c", "light.b", "light.a"]])
    #expect(room.refs(for: .roomDetail).map(\.id).prefix(3) == ["light.c", "light.b", "light.a"])
}

/// (b, the half that discriminates) **It keeps following.** The fallback is resolved on every read,
/// not copied on first use, so changing the arranged surface's list changes the unarranged one too.
///
/// Two rooms differing *only* in the list `.overview` holds, both with `.roomDetail` unset: a
/// copy-on-first-read implementation would give room detail the same answer in both, and only this
/// comparison can tell the two implementations apart. Asserting once that detail matches overview
/// passes either way.
@Test func anUnarrangedSurfaceKeepsFollowingRatherThanSnapshotting() {
    let first = arrangeable([.overview: ["light.c", "light.b", "light.a"]])
    let second = arrangeable([.overview: ["light.b", "light.a", "light.c"]])
    #expect(first.refs(for: .roomDetail).map(\.id).prefix(3) == ["light.c", "light.b", "light.a"])
    #expect(second.refs(for: .roomDetail).map(\.id).prefix(3) == ["light.b", "light.a", "light.c"])
    #expect(first.refs(for: .roomDetail).map(\.id) != second.refs(for: .roomDetail).map(\.id))
}

/// (c) Neither surface arranged: both fall through to `TileOrder.defaultOrder`, unchanged.
@Test func withNeitherSurfaceArrangedBothTakeTheDefaultOrder() {
    let room = arrangeable([:])
    let expected = TileOrder.defaultOrder(["light.a", "light.b", "light.c"])
    #expect(room.refs(for: .overview).map(\.id) == expected)
}

/// (e) **The defect in one test.** Room detail follows the overview's list, which cannot mention the
/// demoted sensor — the overview does not show it, so no drag there could ever have placed it. It
/// arrives as a newcomer at the end, by `TileOrder.resolve`'s rule 2, rather than being dropped.
///
/// Under the single shared list this replaced, an overview drag *stored* a list without the sensor
/// in it, so the sensor's own arranged position was destroyed rather than merely unmentioned. Here
/// nothing was written on room detail at all, so there is nothing to destroy.
@Test func aDetailOnlyRefIsAppendedWhenFollowingTheOverviewsOrder() {
    let room = arrangeable([.overview: ["light.c", "light.b", "light.a"]])
    #expect(room.refs(for: .roomDetail).map(\.id) == ["light.c", "light.b", "light.a", "sensor.demoted"])
    // And the overview is unchanged by the sensor's existence: it never shows it.
    #expect(room.refs(for: .overview).map(\.id) == ["light.c", "light.b", "light.a"])
}

/// An empty stored list is unset, not "arranged into nothing" — otherwise a surface whose list was
/// cleared would stop following its sibling and silently take the default instead.
@Test func anEmptyStoredListIsUnsetRatherThanAnArrangement() {
    let room = arrangeable([.overview: ["light.c", "light.b", "light.a"], .roomDetail: []])
    #expect(room.refs(for: .roomDetail).map(\.id).prefix(3) == ["light.c", "light.b", "light.a"])
}

/// The mirror of `aDetailOnlyRefIsAppendedWhenFollowingTheOverviewsOrder`: **the overview following
/// room detail**, which is the direction the rest of these tests do not exercise.
///
/// It has an asymmetry they do not. The borrowed list mentions `sensor.demoted`, which the overview
/// does not show — so `TileOrder.resolve`'s rule 3 has to drop it rather than leave a hole or sort
/// a phantom. And this is the plausible path now that room detail is arrangeable at all: demoted
/// sensors live only there, so it is where somebody arranges a room for the first time.
@Test func theOverviewFollowsRoomDetailAndDropsWhatItCannotShow() {
    let room = arrangeable([.roomDetail: ["sensor.demoted", "light.c", "light.b", "light.a"]])
    #expect(room.refs(for: .overview).map(\.id) == ["light.c", "light.b", "light.a"])
    #expect(room.refs(for: .roomDetail).map(\.id) == ["sensor.demoted", "light.c", "light.b", "light.a"])
}

/// **The first drag on a following surface makes it stop following.**
///
/// Nothing implements this: it falls out of "write what you moved". A drag reads
/// `refs(for: surface)` — which, on a surface with no list of its own, is the list it *borrowed* —
/// moves one id within it, and writes the whole result to that surface's key. So the act of
/// arranging is also the act of snapshotting, and there is no separate moment where a copy is taken.
///
/// Rendered here as its result, since a `RoomSection` cannot perform a gesture: `moved` is exactly
/// what `TileDropDelegate` would compute and store. The second assertion is the one that matters —
/// the overview has since changed, and room detail no longer cares.
@Test func theFirstDragOnAFollowingSurfaceDivergesFromTheOtherOne() {
    let following = arrangeable([.overview: ["light.c", "light.b", "light.a"]])
    let resolved = following.refs(for: .roomDetail).map(\.id)
    #expect(resolved == ["light.c", "light.b", "light.a", "sensor.demoted"])

    // What a drag of the demoted sensor onto `light.b` writes — `TileOrder.moving`, unchanged, over
    // the borrowed list.
    let moved = TileOrder.moving("sensor.demoted", before: "light.b", in: resolved)
    let diverged = arrangeable([.overview: ["light.a", "light.b", "light.c"], .roomDetail: moved])

    #expect(diverged.refs(for: .roomDetail).map(\.id) == moved)
    // The overview has been rearranged since, and room detail no longer follows it.
    #expect(diverged.refs(for: .overview).map(\.id) == ["light.a", "light.b", "light.c"])
}
