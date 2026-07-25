import Testing
@testable import HavenCore

private func e(_ id: String, _ s: String) -> EntityState {
    .init(entityId: id, state: s, attributes: [:], lastUpdated: .init())
}

@Test func rollups() {
    let ids = ["light.a", "light.b", "cover.c", "sensor.x"]
    let states = ["light.a": e("light.a", "on"), "light.b": e("light.b", "off"),
                  "cover.c": e("cover.c", "open"), "sensor.x": e("sensor.x", "1")]
    let r = RoomRollups.compute(entityIds: ids, states: states)
    let lights = r.first { $0.kind == .lights }!
    #expect(lights.activeCount == 1)
    #expect(lights.total == 2)
    #expect(lights.targetEntityIds.sorted() == ["light.a", "light.b"])
    let covers = r.first { $0.kind == .covers }!
    #expect(covers.activeCount == 1)
    #expect(covers.total == 1)
    #expect(RoomRollups.compute(entityIds: ["sensor.x"], states: states).isEmpty)   // no lights/covers -> none
}
