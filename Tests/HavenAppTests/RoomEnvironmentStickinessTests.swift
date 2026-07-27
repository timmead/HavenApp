import Testing
import Foundation
import HavenCore
@testable import HavenApp

/// **The nomination must not follow live state.**
///
/// `HomeStore.rooms()` is called from inside `DashboardView.body`, so everything it derives from
/// `states` recomputes on every state tick — dozens of times a minute in a real home. Candidacy
/// reads `device_class`, which lives on entity *state*, and an entity that goes `unavailable`
/// arrives with its attributes stripped. Put those together and a nomination recomputed per tick
/// silently switches the room to a *different physical thermometer* the moment the nominated one
/// drops off, then switches back when it returns.
///
/// The property that makes it impossible is that resolution happens once per structure load, not
/// per render: which sensor is the room's is configuration, and only the reading is live data.
///
/// This can't be asserted in HavenCore — `RoomEnvironmentResolver` is a pure function that does
/// whatever it is asked, whenever it is asked. The hazard is entirely in *when the store calls it*.
@Suite @MainActor struct RoomEnvironmentStickinessTests {

    private func state(_ id: String, _ value: String,
                       _ attributes: [String: JSONValue]) -> EntityState {
        EntityState(entityId: id, state: value, attributes: attributes,
                    lastUpdated: Date(timeIntervalSince1970: 0))
    }

    /// A home with one room holding two temperature sensors. `sensor.a_temp` sorts first and so is
    /// the deterministic pick.
    private func store() -> HomeStore {
        let store = HomeStore()
        let areas = [AreaRegistryEntry(areaId: "living", name: "Living", floorId: nil, icon: nil,
                                       temperatureEntityId: nil, humidityEntityId: nil)]
        let entities = ["sensor.a_temp", "sensor.b_temp"].map {
            EntityRegistryEntry(entityId: $0, areaId: "living", deviceId: nil, name: nil)
        }
        store.home = RegistryResolver.resolve(floors: [], areas: areas, devices: [], entities: entities)
        store.states = [
            "sensor.a_temp": state("sensor.a_temp", "21.5",
                                   ["device_class": .string("temperature"),
                                    "unit_of_measurement": .string("°C")]),
            "sensor.b_temp": state("sensor.b_temp", "19.0",
                                   ["device_class": .string("temperature"),
                                    "unit_of_measurement": .string("°C")]),
        ]
        return store
    }

    private func nominatedTemperature(_ store: HomeStore) -> UpliftedSensor? {
        store.rooms().first { $0.areaId == "living" }?.headerSensors.first { $0.role == .temperature }
    }

    @Test func theNominatedSensorSurvivesGoingUnavailable() {
        let store = store()
        store.resolveEnvironment()
        #expect(nominatedTemperature(store)?.entityId == "sensor.a_temp")

        // Exactly what a real `state_changed` push looks like when a device drops off: the state
        // becomes "unavailable" and the attributes — `device_class` included — go with it. This is
        // the mutation that would disqualify it as a candidate if the pick were recomputed here.
        store.states["sensor.a_temp"] = state("sensor.a_temp", "unavailable", [:])

        #expect(nominatedTemperature(store)?.entityId == "sensor.a_temp")
        // And the pill says so honestly, rather than quietly reading the other sensor.
        let sensor = try! #require(nominatedTemperature(store))
        #expect(EnvironmentReading.display(sensor, state: store.state("sensor.a_temp")) == "—")
    }

    /// The reading, unlike the nomination, *is* live: a new value must show up without re-resolving
    /// anything.
    @Test func theReadingStillFollowsLiveState() {
        let store = store()
        store.resolveEnvironment()
        let sensor = try! #require(nominatedTemperature(store))
        #expect(EnvironmentReading.display(sensor, state: store.state(sensor.entityId)) == "21.5°C")

        store.states["sensor.a_temp"] = state("sensor.a_temp", "23.4",
                                              ["device_class": .string("temperature"),
                                               "unit_of_measurement": .string("°C")])
        #expect(EnvironmentReading.display(sensor, state: store.state(sensor.entityId)) == "23.4°C")
    }

    /// A sensor that is offline at resolution time still gets a pill — rendering a proposal is free.
    /// What it must not do is get *persisted*, since a stored nomination is never re-picked.
    @Test func anOfflineSensorIsNominatedForDisplayButNotForPersistence() {
        let store = store()
        store.states["sensor.a_temp"] = state("sensor.a_temp", "unavailable", [:])
        store.resolveEnvironment()

        // `sensor.a_temp` has no `device_class` while unavailable, so `sensor.b_temp` is the only
        // candidate and is shown — but it is not offered for persistence, because a launch that
        // catches the real sensor offline must not permanently record the wrong one.
        let living = try! #require(store.environment["living"])
        #expect(living.temperature?.entityId == "sensor.b_temp")
        #expect(living.nominationsToPersist?.temperature?.entityId == "sensor.b_temp")

        // Now the *nominated* one is the offline one: nothing is offered for persistence at all.
        let offline = HomeStore()
        offline.home = store.home
        offline.states = ["sensor.a_temp": state("sensor.a_temp", "unavailable",
                                                 ["device_class": .string("temperature")])]
        offline.resolveEnvironment()
        let room = try! #require(offline.environment["living"])
        #expect(room.temperature?.entityId == "sensor.a_temp")
        #expect(room.nominationsToPersist == nil)
    }
}
