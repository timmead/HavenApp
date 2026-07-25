import Testing
@testable import HavenCore

@Test func buildsRoomsWithUpliftAndDevices() {
    let areas = [AreaRegistryEntry(areaId: "a", name: "Living", floorId: nil, icon: nil,
                                   temperatureEntityId: "sensor.t", humidityEntityId: "sensor.h")]
    let entities = [EntityRegistryEntry(entityId: "light.l", areaId: "a", deviceId: nil, name: nil),
                    EntityRegistryEntry(entityId: "sensor.t", areaId: "a", deviceId: nil, name: nil),
                    EntityRegistryEntry(entityId: "sensor.h", areaId: "a", deviceId: nil, name: nil),
                    EntityRegistryEntry(entityId: "sensor.power", areaId: "a", deviceId: nil, name: nil)]
    let home = RegistryResolver.resolve(floors: [], areas: areas, devices: [], entities: entities)
    let rooms = SectionBuilder.rooms(from: home)
    let living = rooms.first { $0.name == "Living" }!
    #expect(living.headerSensors.map(\.entityId).sorted() == ["sensor.h","sensor.t"])
    // uplifted temp/humidity are NOT tiles; other entities are
    let deviceIds = living.deviceRefs.map(\.id).sorted()
    #expect(deviceIds == ["light.l","sensor.power"])
}
