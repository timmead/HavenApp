import Testing
@testable import HavenCore

private func ent(_ id: String, area: String? = nil, device: String? = nil) -> EntityRegistryEntry {
    .init(entityId: id, areaId: area, deviceId: device, name: nil)
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

@Test func unassignedEntitiesBucketed() {
    let entities = [ent("sensor.orphan")]
    let home = RegistryResolver.resolve(floors: [], areas: [], devices: [], entities: entities)
    #expect(home.floors.flatMap(\.areas).flatMap(\.entityIds) == ["sensor.orphan"])
    #expect(home.floors.count == 1)
    #expect(home.floors.first?.name == "Home")
}
