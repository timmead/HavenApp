import Testing
@testable import HavenCore

private func e(_ id: String, _ s: String, _ a: [String: JSONValue] = [:]) -> EntityState { .init(entityId: id, state: s, attributes: a, lastUpdated: .init()) }

@Test func sensorState() {
    let s = SensorState(e("sensor.p", "124", ["unit_of_measurement": .string("W"), "device_class": .string("power")]))
    #expect(s.value == "124"); #expect(s.unit == "W"); #expect(s.deviceClass == "power")
    #expect(s.isNumeric); #expect(s.numericValue == 124)
    #expect(!SensorState(e("sensor.x", "home")).isNumeric)
}
@Test func binarySensorState() {
    #expect(BinarySensorState(e("binary_sensor.d", "on", ["device_class": .string("door")])).isActive)
    #expect(!BinarySensorState(e("binary_sensor.d", "off")).isActive)
}
