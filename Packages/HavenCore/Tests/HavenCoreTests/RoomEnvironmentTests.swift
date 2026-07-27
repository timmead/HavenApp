import Testing
import Foundation
@testable import HavenCore

// MARK: - Fixtures

private func entry(_ id: String, category: String? = nil, deviceId: String? = nil,
                   hidden: String? = nil) -> EntityRegistryEntry {
    EntityRegistryEntry(entityId: id, areaId: "living", deviceId: deviceId, name: nil,
                        entityCategory: category, hiddenBy: hidden)
}

/// A home with one area, built through the real `RegistryResolver` so curation tiers are the ones
/// production would compute rather than ones the test asserts into existence.
private func home(_ entries: [EntityRegistryEntry],
                  temperatureEntityId: String? = nil,
                  humidityEntityId: String? = nil) -> ResolvedHome {
    let area = AreaRegistryEntry(areaId: "living", name: "Living", floorId: nil, icon: nil,
                                 temperatureEntityId: temperatureEntityId,
                                 humidityEntityId: humidityEntityId)
    return RegistryResolver.resolve(floors: [], areas: [area], devices: [], entities: entries)
}

private func temperatureSensor() -> RoomEnvironmentSource { .init(deviceClass: "temperature") }
private func humiditySensor() -> RoomEnvironmentSource { .init(deviceClass: "humidity") }
private func thermostat() -> RoomEnvironmentSource {
    .init(deviceClass: nil, hasCurrentTemperature: true, hasCurrentHumidity: true)
}

private func resolve(_ home: ResolvedHome, _ sources: [String: RoomEnvironmentSource],
                     stored: [String: RoomEnvironmentOverride] = [:],
                     isReadable: @escaping (UpliftedSensor) -> Bool = { _ in true }) -> RoomEnvironment {
    RoomEnvironmentResolver.resolve(home: home, sources: sources, stored: stored,
                                    isReadable: isReadable)["living"]!
}

// MARK: - The ladder

@Test func autoPicksATemperatureSensorWhenNothingElseSaysAnything() {
    let env = resolve(home([entry("sensor.lr_temp"), entry("light.lr")]),
                      ["sensor.lr_temp": temperatureSensor()])
    #expect(env.temperature?.entityId == "sensor.lr_temp")
    #expect(env.temperature?.source == .state)
    #expect(env.proposed == [.temperature])
}

@Test func homeAssistantsOwnAreaNominationBeatsTheAutoPick() {
    let env = resolve(home([entry("sensor.a_temp"), entry("sensor.z_temp")],
                           temperatureEntityId: "sensor.z_temp"),
                      ["sensor.a_temp": temperatureSensor(), "sensor.z_temp": temperatureSensor()])
    #expect(env.temperature?.entityId == "sensor.z_temp")
}

@Test func aStoredNominationBeatsBothTheRegistryAndTheAutoPick() {
    let stored = RoomEnvironmentOverride(
        temperature: UpliftedSensor(role: .temperature, entityId: "sensor.chosen", source: .state))
    let env = resolve(home([entry("sensor.a_temp"), entry("sensor.chosen")],
                           temperatureEntityId: "sensor.a_temp"),
                      ["sensor.a_temp": temperatureSensor(), "sensor.chosen": temperatureSensor()],
                      stored: ["living": stored])
    #expect(env.temperature?.entityId == "sensor.chosen")
    // Already in the document — nothing to write back.
    #expect(env.proposed.isEmpty)
}

/// The "keep it and render —" decision. A stored nomination is authoritative even when its entity
/// has left Home Assistant entirely: silently swapping in a different physical device would be a
/// worse answer than saying there is no reading.
@Test func aStoredNominationSurvivesItsEntityVanishing() {
    let stored = RoomEnvironmentOverride(
        temperature: UpliftedSensor(role: .temperature, entityId: "sensor.gone", source: .state))
    let env = resolve(home([entry("sensor.still_here")]),
                      ["sensor.still_here": temperatureSensor()],
                      stored: ["living": stored])
    #expect(env.temperature?.entityId == "sensor.gone")
    #expect(env.proposed.isEmpty)
}

/// Validation is presence in the *document*, not candidacy. A user who deliberately nominates a
/// diagnostic sensor must not have it overruled by a heuristic — that is the opposite of what the
/// ladder is for.
@Test func aStoredNominationNamingANonCandidateIsHonoured() {
    let stored = RoomEnvironmentOverride(
        temperature: UpliftedSensor(role: .temperature, entityId: "sensor.diagnostic", source: .state))
    let env = resolve(home([entry("sensor.diagnostic", category: "diagnostic"), entry("sensor.normal")]),
                      ["sensor.diagnostic": temperatureSensor(), "sensor.normal": temperatureSensor()],
                      stored: ["living": stored])
    #expect(env.temperature?.entityId == "sensor.diagnostic")
    #expect(!env.temperatureCandidates.contains { $0.entityId == "sensor.diagnostic" })
}

// MARK: - Candidacy

/// The load-bearing exclusion. Zigbee/Z-Wave devices routinely expose a `device_class: temperature`
/// diagnostic reporting the device's own internal temperature; without this filter a room would
/// nominate a light bulb's die temperature as the room temperature — and then persist it.
@Test func diagnosticAndHiddenTemperatureSensorsAreNotCandidates() {
    let env = resolve(home([entry("sensor.bulb_temp", category: "diagnostic"),
                            entry("sensor.hidden_temp", hidden: "user"),
                            entry("sensor.real_temp")]),
                      ["sensor.bulb_temp": temperatureSensor(),
                       "sensor.hidden_temp": temperatureSensor(),
                       "sensor.real_temp": temperatureSensor()])
    #expect(env.temperatureCandidates.map(\.entityId) == ["sensor.real_temp"])
}

/// `.companion` telemetry (a device's own battery, link quality, …) is excluded for the same
/// reason. `sensor.motion_battery_temperature` is about the sensor, not the room.
@Test func companionTierSensorsAreNotCandidates() {
    let entries = [entry("sensor.hall_motion_battery", deviceId: "dev-1"), entry("sensor.real_temp")]
    let resolved = home(entries)
    #expect(resolved.floors.flatMap(\.areas).first?.tier(of: "sensor.hall_motion_battery") == .companion)
    let env = resolve(resolved, ["sensor.hall_motion_battery": temperatureSensor(),
                                 "sensor.real_temp": temperatureSensor()])
    #expect(env.temperatureCandidates.map(\.entityId) == ["sensor.real_temp"])
}

@Test func aSensorWithoutTheRightDeviceClassIsNotACandidate() {
    let env = resolve(home([entry("sensor.power"), entry("sensor.temp")]),
                      ["sensor.power": .init(deviceClass: "power"),
                       "sensor.temp": temperatureSensor()])
    #expect(env.temperatureCandidates.map(\.entityId) == ["sensor.temp"])
}

/// No name heuristics, deliberately: a sensor that never declared a device class is not a
/// candidate however suggestively it is named.
@Test func aSuggestivelyNamedSensorWithNoDeviceClassIsNotACandidate() {
    let env = resolve(home([entry("sensor.hall_temperature")]),
                      ["sensor.hall_temperature": .init(deviceClass: nil)])
    #expect(env.temperatureCandidates.isEmpty)
    #expect(env.temperature == nil)
}

/// An entity with no live state is not a candidate — candidacy reads `device_class` from state.
@Test func anEntityAbsentFromSourcesIsNotACandidate() {
    let env = resolve(home([entry("sensor.temp")]), [:])
    #expect(env.temperatureCandidates.isEmpty)
}

/// Arbitrary, but deterministic: the winner is about to be written into shared household
/// configuration, so a pick that varied by device or by launch would have two phones overwriting
/// each other forever.
@Test func multipleCandidatesResolveDeterministicallyByEntityId() {
    let entries = [entry("sensor.z_temp"), entry("sensor.a_temp"), entry("sensor.m_temp")]
    let sources = ["sensor.z_temp": temperatureSensor(), "sensor.a_temp": temperatureSensor(),
                   "sensor.m_temp": temperatureSensor()]
    let env = resolve(home(entries), sources)
    #expect(env.temperature?.entityId == "sensor.a_temp")
    #expect(env.temperatureCandidates.map(\.entityId) == ["sensor.a_temp", "sensor.m_temp", "sensor.z_temp"])
    // Same answer whatever order the registry hands them over in.
    #expect(resolve(home(entries.reversed()), sources).temperature?.entityId == "sensor.a_temp")
}

// MARK: - Thermostats

/// A dedicated thermometer measures the room; a thermostat measures wherever the thermostat is.
@Test func aSensorOutranksAThermostat() {
    let env = resolve(home([entry("climate.lr"), entry("sensor.z_temp")]),
                      ["climate.lr": thermostat(), "sensor.z_temp": temperatureSensor()])
    #expect(env.temperature?.entityId == "sensor.z_temp")
    #expect(env.temperatureCandidates.map(\.entityId) == ["sensor.z_temp", "climate.lr"])
}

/// The common room shape this rung exists for: a thermostat and nothing else.
@Test func aThermostatOnlyRoomGetsBothPillsFromTheClimateEntity() {
    let env = resolve(home([entry("climate.lr")]), ["climate.lr": thermostat()])
    #expect(env.temperature == UpliftedSensor(role: .temperature, entityId: "climate.lr",
                                              source: .attribute("current_temperature")))
    #expect(env.humidity == UpliftedSensor(role: .humidity, entityId: "climate.lr",
                                           source: .attribute("current_humidity")))
    // Two distinct sensors despite naming one entity — the identity the chips `ForEach` depends on.
    #expect(env.headerSensors.count == 2)
    #expect(Set(env.headerSensors.map(\.id)).count == 2)
}

/// A thermostat that reports temperature but not humidity must not manufacture a humidity pill.
@Test func aThermostatWithoutHumidityOffersNoHumidityCandidate() {
    let env = resolve(home([entry("climate.lr")]),
                      ["climate.lr": .init(deviceClass: nil, hasCurrentTemperature: true)])
    #expect(env.temperature != nil)
    #expect(env.humidity == nil)
    #expect(env.humidityCandidates.isEmpty)
}

// MARK: - What is safe to persist

/// Rendering a proposal is free; writing one sticks, because a stored nomination is never
/// re-picked. A launch that catches the room's sensor offline must not permanently record a
/// different one.
@Test func anUnreadableProposalRendersButIsNotOfferedForPersistence() {
    let env = resolve(home([entry("sensor.temp")]), ["sensor.temp": temperatureSensor()],
                      isReadable: { _ in false })
    #expect(env.temperature?.entityId == "sensor.temp")
    #expect(env.proposed.isEmpty)
    #expect(env.nominationsToPersist == nil)
}

@Test func aReadableProposalIsOfferedForPersistence() {
    let env = resolve(home([entry("sensor.temp"), entry("sensor.hum")]),
                      ["sensor.temp": temperatureSensor(), "sensor.hum": humiditySensor()])
    #expect(env.proposed == [.temperature, .humidity])
    #expect(env.nominationsToPersist?.temperature?.entityId == "sensor.temp")
    #expect(env.nominationsToPersist?.humidity?.entityId == "sensor.hum")
}

/// One role readable and the other not must persist only the readable one, not neither and not
/// both.
@Test func persistenceIsDecidedPerRole() {
    let env = resolve(home([entry("sensor.temp"), entry("sensor.hum")]),
                      ["sensor.temp": temperatureSensor(), "sensor.hum": humiditySensor()],
                      isReadable: { $0.role == .temperature })
    #expect(env.proposed == [.temperature])
    #expect(env.nominationsToPersist?.temperature?.entityId == "sensor.temp")
    #expect(env.nominationsToPersist?.humidity == nil)
}

// MARK: - Empty rooms

@Test func aRoomWithNothingToReadHasNoPillsAndNothingToWrite() {
    let env = resolve(home([entry("light.lr")]), ["light.lr": .init(deviceClass: nil)])
    #expect(env.headerSensors.isEmpty)
    #expect(env.nominationsToPersist == nil)
}
