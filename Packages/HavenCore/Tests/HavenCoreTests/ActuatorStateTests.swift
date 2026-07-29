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

/// `isConditioning` is what lights the tile, and the four cases it has to get right are the four
/// that used to be one: on-and-running, on-and-idle, on-with-a-device-that-doesn't-say, and
/// unreachable-with-stale-attributes.
@Test func climateIsConditioning() {
    func climate(_ st: String, action: String? = nil) -> ClimateState {
        ClimateState(e("climate.h", st, action.map { ["hvac_action": .string($0)] } ?? [:]))
    }

    // Running.
    #expect(climate("heat", action: "heating").isConditioning)
    #expect(climate("cool", action: "cooling").isConditioning)
    // Not enumerated as a whitelist, so values HA added later still read as active.
    #expect(climate("heat", action: "preheating").isConditioning)
    #expect(climate("dry", action: "drying").isConditioning)

    // On, at target, doing nothing — the case this property exists to separate out.
    #expect(climate("heat", action: "idle").isOn)
    #expect(!climate("heat", action: "idle").isConditioning)
    // `hvac_action: off` under a non-`off` mode is contradictory but HA emits it; treat the
    // action as the truth about the equipment.
    #expect(!climate("heat", action: "off").isConditioning)

    // The attribute is absent — a large share of integrations never send it. Falls back to `isOn`
    // rather than to "idle", which would silently kill the fill on all of that hardware.
    #expect(climate("heat").isConditioning)
    #expect(!climate("off").isConditioning)

    // Unreachable wins over whatever stale action the last-known attributes still carry.
    #expect(!climate("unavailable", action: "heating").isConditioning)
    #expect(!climate("unknown", action: "heating").isConditioning)

    #expect(climate("heat", action: "heating").hvacAction == "heating")
    #expect(climate("heat").hvacAction == nil)
}

/// `function` is what colours a thermostat — heating red, cooling blue, drying purple, fan green —
/// and it is a reading of two Home Assistant vocabularies that deliberately do not match each
/// other. Every row here is a string HA actually emits.
@Test func climateFunctionReadsTheActionFirstAndTheModeSecond() {
    func climate(_ st: String, action: String? = nil) -> ClimateState {
        ClimateState(e("climate.h", st, action.map { ["hvac_action": .string($0)] } ?? [:]))
    }

    // The action wins where it says something.
    #expect(climate("heat", action: "heating").function == .heat)
    #expect(climate("cool", action: "cooling").function == .cool)
    #expect(climate("dry", action: "drying").function == .dry)
    #expect(climate("fan_only", action: "fan").function == .fan)

    // The mode carries an idle thermostat, so a tile does not lose its colour the moment the room
    // reaches temperature. `idle` and `off` are absent from the action table for exactly this.
    #expect(climate("heat", action: "idle").function == .heat)
    #expect(climate("cool", action: "idle").function == .cool)
    #expect(climate("heat").function == .heat)

    // The two vocabularies differ, which is why there are two tables: HA's mode for drying is
    // `dry` and its action is `drying`; its mode for a fan is `fan_only` and its action is `fan`.
    // A single shared lookup would return nothing for half of these.
    #expect(climate("dry").function == .dry)
    #expect(climate("fan_only").function == .fan)

    // A `heat_cool` unit doing nothing has no true colour and says so — but while it is actually
    // cooling there is exactly one right answer, which is the case the action-first order exists
    // for.
    #expect(climate("heat_cool").function == .unspecified)
    #expect(climate("auto").function == .unspecified)
    #expect(climate("heat_cool", action: "cooling").function == .cool)
    #expect(climate("heat_cool", action: "heating").function == .heat)

    // Off and unreachable keep the domain's own colour rather than a claim.
    #expect(climate("off").function == .unspecified)
    #expect(climate("unavailable").function == .unspecified)
    #expect(climate("unknown").function == .unspecified)

    // Actions HA added later (`preheating`, `defrosting`) are not in the table and fall through to
    // the mode, which for a heating unit is the colour they should have anyway.
    #expect(climate("heat", action: "preheating").function == .heat)
    #expect(climate("heat", action: "defrosting").function == .heat)
}
