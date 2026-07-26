import Testing
@testable import HavenCore

@Test func parsesDomains() {
    #expect(Domain.of("light.kitchen") == .light)
    #expect(Domain.of("switch.plug") == .switchOutlet)
    #expect(Domain.of("cover.blinds") == .cover)
    #expect(Domain.of("lock.front") == .lock)
    #expect(Domain.of("climate.hall") == .climate)
    #expect(Domain.of("scene.movie") == .scene)
    #expect(Domain.of("binary_sensor.door") == .binarySensor)
    #expect(Domain.of("sensor.power") == .sensor)
    #expect(Domain.of("media_player.tv") == .mediaPlayer)  // in scope as of D.2 Task 3
    #expect(Domain.of("camera.porch") == .camera)          // in scope as of D.2 Task 4
    #expect(Domain.of("fan.attic") == .unknown)         // fan is NOT in the D catalog -> Generic
}
@Test func serviceDomainComesFromEntityIdPrefix() {
    // input_boolean.x must call input_boolean.turn_on, NOT switch.turn_on
    #expect(Domain.serviceDomain(of: "input_boolean.guest") == "input_boolean")
    #expect(Domain.serviceDomain(of: "switch.plug") == "switch")
    #expect(Domain.serviceDomain(of: "light.k") == "light")
}
@Test func actuatorFlag() {
    #expect(Domain.light.isActuator)
    #expect(!Domain.sensor.isActuator)
    #expect(!Domain.binarySensor.isActuator)
    // A camera is watched, not operated. Marking it an actuator would put it in reach of the room
    // roll-ups and their bulk actions, which act on things that turn on and off.
    #expect(!Domain.camera.isActuator)
}
@Test func deviceClassAccessor() {
    let s = EntityState(entityId: "binary_sensor.d", state: "on",
                        attributes: ["device_class": .string("door")], lastUpdated: .init())
    #expect(s.deviceClass == "door")
}
