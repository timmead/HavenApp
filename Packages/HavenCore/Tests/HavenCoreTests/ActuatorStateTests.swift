import Testing
@testable import HavenCore

private func e(_ id: String, _ st: String, _ a: [String: JSONValue] = [:]) -> EntityState {
    EntityState(entityId: id, state: st, attributes: a, lastUpdated: .init())
}

@Test func lightState() {
    let s = LightState(e("light.k", "on", ["brightness": .int(191), "supported_color_modes": .array([.string("color_temp")])]))
    #expect(s.isOn); #expect(s.brightnessPercent == 75)   // 191/255 ≈ 75
    #expect(s.supportsBrightness); #expect(s.supportsColorTemp)
    #expect(!LightState(e("light.k", "off")).isOn)
}
@Test func lightColorTempRange() {
    let withBounds = LightState(e("light.k", "on", [
        "supported_color_modes": .array([.string("color_temp")]),
        "color_temp_kelvin": .int(3200), "min_color_temp_kelvin": .int(2000), "max_color_temp_kelvin": .int(6500),
    ]))
    #expect(withBounds.colorTempKelvin == 3200)
    #expect(withBounds.colorTempRange == 2000...6500)

    // No hardcoded fallback range: missing bounds must yield `nil`, not a guessed default —
    // a wrong guess would send an out-of-range command HA clamps silently rather than rejects.
    #expect(LightState(e("light.k", "on", ["supported_color_modes": .array([.string("color_temp")])])).colorTempRange == nil)

    // Degenerate/inverted bounds are equally untrustworthy.
    let inverted = LightState(e("light.k", "on", ["min_color_temp_kelvin": .int(6500), "max_color_temp_kelvin": .int(2000)]))
    #expect(inverted.colorTempRange == nil)
}
@Test func coverState() {
    let s = CoverState(e("cover.b", "open", ["current_position": .int(60)]))
    #expect(s.isOpen); #expect(s.positionPercent == 60); #expect(s.supportsPosition)
    #expect(!CoverState(e("cover.b", "closed")).isOpen)
}
@Test func lockState() {
    #expect(LockState(e("lock.f", "locked")).isLocked)
    #expect(LockState(e("lock.f", "jammed")).isJammed)
    #expect(!LockState(e("lock.f", "unlocked")).isLocked)
}
@Test func climateState() {
    let s = ClimateState(e("climate.h", "heat", [
        "current_temperature": .double(70), "temperature": .double(72),
        "hvac_modes": .array([.string("off"), .string("heat"), .string("cool")]),
        "fan_mode": .string("auto"), "fan_modes": .array([.string("auto"), .string("low")]),
    ]))
    #expect(s.isOn); #expect(s.currentTemp == 70); #expect(s.targetTemp == 72)
    #expect(s.hvacMode == "heat"); #expect(s.modes == ["off","heat","cool"]); #expect(s.fanMode == "auto")
    #expect(!ClimateState(e("climate.h", "off")).isOn)
}
