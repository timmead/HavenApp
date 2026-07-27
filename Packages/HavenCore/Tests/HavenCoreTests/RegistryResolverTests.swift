import Testing
@testable import HavenCore

private func ent(_ id: String, area: String? = nil, device: String? = nil, disabledBy: String? = nil) -> EntityRegistryEntry {
    .init(entityId: id, areaId: area, deviceId: device, name: nil, disabledBy: disabledBy)
}

@Test func entityInheritsAreaFromDevice() {
    let floors = [FloorRegistryEntry(floorId: "f1", name: "Ground", level: 0, icon: nil)]
    let areas = [AreaRegistryEntry(areaId: "a1", name: "Kitchen", floorId: "f1", icon: nil,
                                   temperatureEntityId: nil, humidityEntityId: nil)]
    let devices = [DeviceRegistryEntry(id: "d1", areaId: "a1", name: "Hue", nameByUser: nil)]
    let entities = [ent("light.kitchen", area: nil, device: "d1")]   // inherits a1 from device
    let home = RegistryResolver.resolve(floors: floors, areas: areas, devices: devices, entities: entities)
    #expect(home.floors.first?.areas.first?.entityIds == ["light.kitchen"])
}

@Test func directEntityAreaOverridesDevice() {
    let areas = [AreaRegistryEntry(areaId: "a1", name: "Kitchen", floorId: nil, icon: nil, temperatureEntityId: nil, humidityEntityId: nil),
                 AreaRegistryEntry(areaId: "a2", name: "Den", floorId: nil, icon: nil, temperatureEntityId: nil, humidityEntityId: nil)]
    let devices = [DeviceRegistryEntry(id: "d1", areaId: "a1", name: nil, nameByUser: nil)]
    let entities = [ent("light.x", area: "a2", device: "d1")]        // direct a2 wins
    let home = RegistryResolver.resolve(floors: [], areas: areas, devices: devices, entities: entities)
    let den = home.floors.flatMap(\.areas).first { $0.name == "Den" }
    #expect(den?.entityIds == ["light.x"])
}

@Test func floorsSortedByLevel() {
    let floors = [FloorRegistryEntry(floorId: "up", name: "Upstairs", level: 1, icon: nil),
                  FloorRegistryEntry(floorId: "base", name: "Basement", level: -1, icon: nil)]
    let areas = [AreaRegistryEntry(areaId: "a", name: "A", floorId: "up", icon: nil, temperatureEntityId: nil, humidityEntityId: nil),
                 AreaRegistryEntry(areaId: "b", name: "B", floorId: "base", icon: nil, temperatureEntityId: nil, humidityEntityId: nil)]
    let home = RegistryResolver.resolve(floors: floors, areas: areas, devices: [], entities: [])
    #expect(home.floors.map(\.name) == ["Basement", "Upstairs"])
    #expect(home.floors.first?.areas.first?.id == "b")
}

@Test func homeFloorLeadsTheRealFloors() {
    let floors = [FloorRegistryEntry(floorId: "up", name: "Upstairs", level: 1, icon: nil),
                  FloorRegistryEntry(floorId: "base", name: "Basement", level: -1, icon: nil)]
    let areas = [AreaRegistryEntry(areaId: "a", name: "A", floorId: "up", icon: nil, temperatureEntityId: nil, humidityEntityId: nil),
                 AreaRegistryEntry(areaId: "b", name: "B", floorId: "base", icon: nil, temperatureEntityId: nil, humidityEntityId: nil)]
    // One orphan is all it takes to conjure the synthetic floor.
    let home = RegistryResolver.resolve(floors: floors, areas: areas, devices: [], entities: [ent("sensor.orphan")])
    #expect(home.floors.map(\.name) == ["Home", "Basement", "Upstairs"])
}

@Test func homeAbsentWhenEverythingIsFiled() {
    let floors = [FloorRegistryEntry(floorId: "up", name: "Upstairs", level: 1, icon: nil)]
    let areas = [AreaRegistryEntry(areaId: "a", name: "A", floorId: "up", icon: nil, temperatureEntityId: nil, humidityEntityId: nil)]
    let home = RegistryResolver.resolve(floors: floors, areas: areas, devices: [], entities: [ent("light.a", area: "a")])
    #expect(home.floors.map(\.name) == ["Upstairs"])
}

/// Equal levels are the *ordinary* case — HA leaves `level` unset on most floors and the resolver
/// folds nil to 0 — so registry order has to break the tie deterministically. `sorted(by:)` alone
/// makes no such promise.
@Test func floorsWithEqualLevelsKeepRegistryOrder() {
    let floors = [FloorRegistryEntry(floorId: "f1", name: "Loft", level: nil, icon: nil),
                  FloorRegistryEntry(floorId: "f2", name: "Annex", level: nil, icon: nil),
                  FloorRegistryEntry(floorId: "f3", name: "Garage", level: nil, icon: nil)]
    let areas = [AreaRegistryEntry(areaId: "a1", name: "A", floorId: "f1", icon: nil, temperatureEntityId: nil, humidityEntityId: nil),
                 AreaRegistryEntry(areaId: "a2", name: "B", floorId: "f2", icon: nil, temperatureEntityId: nil, humidityEntityId: nil),
                 AreaRegistryEntry(areaId: "a3", name: "C", floorId: "f3", icon: nil, temperatureEntityId: nil, humidityEntityId: nil)]
    let home = RegistryResolver.resolve(floors: floors, areas: areas, devices: [], entities: [ent("sensor.orphan")])
    #expect(home.floors.map(\.name) == ["Home", "Loft", "Annex", "Garage"])
}

@Test func unassignedEntitiesBucketed() {
    let entities = [ent("sensor.orphan")]
    let home = RegistryResolver.resolve(floors: [], areas: [], devices: [], entities: entities)
    #expect(home.floors.flatMap(\.areas).flatMap(\.entityIds) == ["sensor.orphan"])
    #expect(home.floors.count == 1)
    #expect(home.floors.first?.name == "Home")
}

@Test func areaWithUnknownFloorFoldsIntoHome() {
    let floors = [FloorRegistryEntry(floorId: "real", name: "Real Floor", level: 0, icon: nil)]
    let areas = [AreaRegistryEntry(areaId: "a", name: "Ghost Room", floorId: "ghost", icon: nil,
                                   temperatureEntityId: nil, humidityEntityId: nil)]
    let entities = [EntityRegistryEntry(entityId: "light.ghost", areaId: "a", deviceId: nil, name: nil)]
    let home = RegistryResolver.resolve(floors: floors, areas: areas, devices: [], entities: entities)
    // The ghost-floor area must NOT vanish; it should appear under the synthetic "Home" floor.
    let allEntities = home.floors.flatMap(\.areas).flatMap(\.entityIds)
    #expect(allEntities.contains("light.ghost"))
    #expect(home.floors.contains { $0.name == "Home" && $0.areas.contains { $0.id == "a" } })
}

@Test func disabledEntitiesExcludedFromEveryArea() {
    let areas = [AreaRegistryEntry(areaId: "a1", name: "Kitchen", floorId: nil, icon: nil,
                                   temperatureEntityId: nil, humidityEntityId: nil)]
    let entities = [ent("light.disabled", area: "a1", disabledBy: "user"),
                    ent("light.enabled", area: "a1")]
    let home = RegistryResolver.resolve(floors: [], areas: areas, devices: [], entities: entities)
    let allEntities = home.floors.flatMap(\.areas).flatMap(\.entityIds)
    #expect(!allEntities.contains("light.disabled"))
    #expect(allEntities.contains("light.enabled"))
}

@Test func areaCarriesClimateEntities() {
    let areas = [AreaRegistryEntry(areaId: "a", name: "Kitchen", floorId: nil, icon: nil,
                                   temperatureEntityId: "sensor.kt", humidityEntityId: "sensor.kh")]
    let home = RegistryResolver.resolve(floors: [], areas: areas, devices: [], entities: [])
    let area = home.floors.flatMap(\.areas).first { $0.id == "a" }
    #expect(area?.temperatureEntityId == "sensor.kt")
    #expect(area?.humidityEntityId == "sensor.kh")
}
