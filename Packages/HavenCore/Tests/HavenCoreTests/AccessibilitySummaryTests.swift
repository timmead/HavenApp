import Testing
@testable import HavenCore

private func e(_ id: String, _ st: String, _ a: [String: JSONValue] = [:]) -> EntityState {
    EntityState(entityId: id, state: st, attributes: a, lastUpdated: .init())
}

@Test func accessibilitySummaryLight() {
    let on = LightState(e("light.k", "on", ["brightness": .int(153)]))   // 153/255 = 60%
    #expect(AccessibilitySummary.light("Kitchen light", on) == "Kitchen light, on, 60% brightness")

    let onNoBrightness = LightState(e("light.k", "on"))
    #expect(AccessibilitySummary.light("Kitchen light", onNoBrightness) == "Kitchen light, on")

    let off = LightState(e("light.k", "off", ["brightness": .int(153)]))
    // Off must win even with a stale brightness attribute still present in `attributes` —
    // this is the same isOn-gating trap the brightness slider itself already paid for.
    #expect(AccessibilitySummary.light("Kitchen light", off) == "Kitchen light, off")
}

@Test func accessibilitySummarySwitch() {
    #expect(AccessibilitySummary.switchOutlet("Fan", isOn: true) == "Fan, on")
    #expect(AccessibilitySummary.switchOutlet("Fan", isOn: false) == "Fan, off")
}

@Test func accessibilitySummaryCover() {
    let open = CoverState(e("cover.b", "open", ["current_position": .int(80)]))
    #expect(AccessibilitySummary.cover("Blinds", open) == "Blinds, open, 80% open")
    let closed = CoverState(e("cover.b", "closed"))
    #expect(AccessibilitySummary.cover("Blinds", closed) == "Blinds, closed")
}

@Test func accessibilitySummaryLock() {
    #expect(AccessibilitySummary.lock("Front door", LockState(e("lock.f", "locked"))) == "Front door, locked")
    #expect(AccessibilitySummary.lock("Front door", LockState(e("lock.f", "unlocked"))) == "Front door, unlocked")
    #expect(AccessibilitySummary.lock("Front door", LockState(e("lock.f", "jammed"))) == "Front door, jammed")
}

@Test func accessibilitySummaryClimate() {
    let heating = ClimateState(e("climate.h", "heat", ["temperature": .double(72)]))
    #expect(AccessibilitySummary.climate("Thermostat", heating) == "Thermostat, heat, target 72°")
    let off = ClimateState(e("climate.h", "off"))
    #expect(AccessibilitySummary.climate("Thermostat", off) == "Thermostat, off")
}

@Test func accessibilitySummaryBinarySensorAndSensor() {
    #expect(AccessibilitySummary.binarySensor("Front door", BinarySensorState(e("binary_sensor.d", "on"))) == "Front door, active")
    #expect(AccessibilitySummary.binarySensor("Front door", BinarySensorState(e("binary_sensor.d", "off"))) == "Front door, clear")
    let temp = SensorState(e("sensor.t", "68.5", ["unit_of_measurement": .string("°F")]))
    #expect(AccessibilitySummary.sensor("Living room temperature", temp) == "Living room temperature, 68.5 °F")
}

@Test func accessibilitySummarySceneAndGeneric() {
    #expect(AccessibilitySummary.scene("Movie night") == "Movie night, scene")
    #expect(AccessibilitySummary.generic("Mystery entity", rawState: "unknown") == "Mystery entity, unknown")
}
