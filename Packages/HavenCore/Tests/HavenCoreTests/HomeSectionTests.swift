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
    let rooms = SectionBuilder.rooms(from: home, environment: env, overrides: [:])
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
    let living = SectionBuilder.rooms(from: home, environment: env, overrides: [:]).first!
    #expect(living.headerSensors.count == 2)
    #expect(living.deviceRefs.map(\.id) == ["climate.lr"])
}

/// A home with no resolved environment renders no pills, and loses no tiles doing so.
@Test func anEmptyEnvironmentLeavesEveryEntityAsATile() {
    let areas = [AreaRegistryEntry(areaId: "a", name: "Living", floorId: nil, icon: nil,
                                   temperatureEntityId: nil, humidityEntityId: nil)]
    let entities = [EntityRegistryEntry(entityId: "sensor.t", areaId: "a", deviceId: nil, name: nil)]
    let home = RegistryResolver.resolve(floors: [], areas: areas, devices: [], entities: entities)
    let living = SectionBuilder.rooms(from: home, environment: [:], overrides: [:]).first!
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
    let rooms = SectionBuilder.rooms(from: home, environment: [:], overrides: [
        // Off the dashboard, still in room detail — the case this whole design exists for.
        "light.a": [.overview: .hidden],
        // On the dashboard though curation demoted it.
        "sensor.b": [.overview: .shown],
        // Home Assistant hid this one; a stored override must not resurrect it.
        "light.hidden": [.overview: .shown],
    ])
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
    let room = SectionBuilder.rooms(from: home, environment: [:], overrides: [:])[0]
    #expect(room.refs(for: .overview).map(\.id) == ["light.a"])
    #expect(room.refs(for: .roomDetail).map(\.id) == ["light.a", "sensor.b"])
}
