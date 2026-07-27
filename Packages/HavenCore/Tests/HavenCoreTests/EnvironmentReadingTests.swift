import Testing
import Foundation
@testable import HavenCore

private func state(_ id: String, _ value: String,
                   _ attributes: [String: JSONValue] = [:]) -> EntityState {
    EntityState(entityId: id, state: value, attributes: attributes, lastUpdated: Date(timeIntervalSince1970: 0))
}

private let temp = UpliftedSensor(role: .temperature, entityId: "sensor.t", source: .state)
private let humid = UpliftedSensor(role: .humidity, entityId: "sensor.h", source: .state)
private let thermostatTemp = UpliftedSensor(role: .temperature, entityId: "climate.lr",
                                            source: .attribute("current_temperature"))
private let thermostatHumid = UpliftedSensor(role: .humidity, entityId: "climate.lr",
                                             source: .attribute("current_humidity"))

// MARK: - Formatting

@Test func temperatureKeepsOneDecimalAndItsRealUnit() {
    let s = state("sensor.t", "21.53", ["unit_of_measurement": .string("°C")])
    #expect(EnvironmentReading.display(temp, state: s) == "21.5°C")
}

@Test func aTrailingZeroDecimalIsDropped() {
    let s = state("sensor.t", "22.0", ["unit_of_measurement": .string("°C")])
    #expect(EnvironmentReading.display(temp, state: s) == "22°C")
}

@Test func fahrenheitIsShownAsFahrenheit() {
    let s = state("sensor.t", "71.6", ["unit_of_measurement": .string("°F")])
    #expect(EnvironmentReading.display(temp, state: s) == "71.6°F")
}

@Test func humidityIsAWholePercent() {
    let s = state("sensor.h", "44.6", ["unit_of_measurement": .string("%")])
    #expect(EnvironmentReading.display(humid, state: s) == "45%")
}

/// A bare degree sign is honest about a temperature whose scale the entity never declared.
@Test func aMissingUnitFallsBackToABareDegree() {
    #expect(EnvironmentReading.display(temp, state: state("sensor.t", "19")) == "19°")
    #expect(EnvironmentReading.display(humid, state: state("sensor.h", "50")) == "50%")
}

/// `format` is the shared formatter `display` and the room history scrub readout both go through —
/// pinned directly, and against a non-default unit, so a Fahrenheit home can't drift back to a
/// hand-rolled `String(format: "%.1f")` plus a hardcoded "°" the way the scrub readout once did.
@Test func theSharedFormatterAppliesToBothRolesAndAnyUnit() {
    #expect(EnvironmentReading.format(71.6, role: .temperature, unit: "°F") == "71.6°F")
    #expect(EnvironmentReading.format(21.0, role: .temperature, unit: "°C") == "21°C")
    #expect(EnvironmentReading.format(44.6, role: .humidity, unit: "%") == "45%")
}

// MARK: - The absence cases

/// The bug this replaces: the previous inline `state + "°"` rendered the literal string
/// `"unavailable°"` on any sensor that dropped off.
@Test func unavailableRendersAnEmDashAndNoUnit() {
    let s = state("sensor.t", "unavailable", ["unit_of_measurement": .string("°C")])
    #expect(EnvironmentReading.display(temp, state: s) == "—")
}

@Test func everyOtherAbsenceAlsoRendersAnEmDash() {
    #expect(EnvironmentReading.display(temp, state: nil) == "—")
    #expect(EnvironmentReading.display(temp, state: state("sensor.t", "unknown")) == "—")
    #expect(EnvironmentReading.display(temp, state: state("sensor.t", "not a number")) == "—")
    // An attribute source whose attribute simply isn't there.
    #expect(EnvironmentReading.display(thermostatTemp, state: state("climate.lr", "heat")) == "—")
    // `Double("nan")` and friends all parse successfully in Swift, unlike ordinary garbage text —
    // so these need their own guard, not just the `Double(...)` failure above. Unguarded, the
    // humidity branch of `format` traps on `Int(inf.rounded())` and the temperature branch renders
    // the literal string "nan°C".
    #expect(EnvironmentReading.display(temp, state: state("sensor.t", "nan")) == "—")
    #expect(EnvironmentReading.display(temp, state: state("sensor.t", "inf")) == "—")
    #expect(EnvironmentReading.display(temp, state: state("sensor.t", "infinity")) == "—")
    #expect(EnvironmentReading.display(temp, state: state("sensor.t", "-inf")) == "—")
    #expect(EnvironmentReading.display(humid, state: state("sensor.h", "nan")) == "—")
    #expect(EnvironmentReading.display(humid, state: state("sensor.h", "inf")) == "—")
}

/// The invariant the persistence guard rests on: `value` is nil in exactly the cases `display`
/// shows an em-dash. If these ever drift apart, a room could persist a nomination it cannot read.
@Test func valueIsNilInExactlyTheCasesDisplayShowsAnEmDash() {
    let cases: [(UpliftedSensor, EntityState?)] = [
        (temp, nil),
        (temp, state("sensor.t", "unavailable")),
        (temp, state("sensor.t", "unknown")),
        (temp, state("sensor.t", "gibberish")),
        (temp, state("sensor.t", "21.5", ["unit_of_measurement": .string("°C")])),
        (humid, state("sensor.h", "50")),
        (thermostatTemp, state("climate.lr", "heat")),
        (thermostatTemp, state("climate.lr", "heat", ["current_temperature": .double(20)])),
        // An unavailable thermostat: the attribute may linger, but there is no reading.
        (thermostatTemp, state("climate.lr", "unavailable", ["current_temperature": .double(20)])),
        // Non-finite states: `Double(...)` parses these successfully, so they need their own
        // guard rather than riding along with the ordinary-garbage-text case above.
        (temp, state("sensor.t", "nan")),
        (temp, state("sensor.t", "inf")),
        (temp, state("sensor.t", "infinity")),
        (temp, state("sensor.t", "-inf")),
        (humid, state("sensor.h", "nan")),
        (humid, state("sensor.h", "inf")),
    ]
    for (sensor, s) in cases {
        let isNil = EnvironmentReading.value(sensor, state: s) == nil
        let isDash = EnvironmentReading.display(sensor, state: s) == "—"
        #expect(isNil == isDash, "disagreement for \(sensor.entityId) / \(s?.state ?? "nil")")
    }
}

// MARK: - Climate attribute sources

/// A thermostat states its scale in `temperature_unit`; `unit_of_measurement` describes nothing on
/// a climate entity.
@Test func aThermostatReadsCurrentTemperatureAndItsOwnUnit() {
    let s = state("climate.lr", "heat", ["current_temperature": .double(20.5),
                                         "temperature_unit": .string("°C")])
    #expect(EnvironmentReading.display(thermostatTemp, state: s) == "20.5°C")
}

@Test func aThermostatHumidityIsAlwaysAPercent() {
    let s = state("climate.lr", "cool", ["current_humidity": .int(48)])
    #expect(EnvironmentReading.display(thermostatHumid, state: s) == "48%")
}

/// The temperature attribute must not be read for a humidity pill, or a thermostat-only room shows
/// the same number twice.
@Test func eachRoleReadsItsOwnAttribute() {
    let s = state("climate.lr", "heat", ["current_temperature": .double(20.5),
                                         "current_humidity": .int(48)])
    #expect(EnvironmentReading.display(thermostatTemp, state: s) == "20.5°")
    #expect(EnvironmentReading.display(thermostatHumid, state: s) == "48%")
}
