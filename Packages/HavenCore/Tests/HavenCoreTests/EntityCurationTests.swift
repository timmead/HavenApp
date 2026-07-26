import Foundation
import Testing
@testable import HavenCore

private func reg(_ id: String, area: String? = "a", device: String? = nil,
                 category: String? = nil, hiddenBy: String? = nil, disabledBy: String? = nil) -> EntityRegistryEntry {
    .init(entityId: id, areaId: area, deviceId: device, name: nil, disabledBy: disabledBy,
          entityCategory: category, hiddenBy: hiddenBy)
}

/// Runs the real pipeline — resolver → curation → sections — so the tiers are asserted through
/// the surfaces that consume them, not just the pure function in isolation.
private func room(_ entities: [EntityRegistryEntry], temperature: String? = nil, humidity: String? = nil) -> RoomSection {
    let areas = [AreaRegistryEntry(areaId: "a", name: "Kitchen", floorId: nil, icon: nil,
                                   temperatureEntityId: temperature, humidityEntityId: humidity)]
    let home = RegistryResolver.resolve(floors: [], areas: areas, devices: [], entities: entities)
    return SectionBuilder.rooms(from: home).first { $0.areaId == "a" }!
}

// MARK: - Single-entity classification

@Test func configAndDiagnosticEntitiesAreHidden() {
    #expect(EntityCuration.tier(of: reg("switch.printer_restart", category: "config")) == .hidden)
    #expect(EntityCuration.tier(of: reg("sensor.hall_rssi", category: "diagnostic")) == .hidden)
    #expect(EntityCuration.tier(of: reg("sensor.hall_rssi", category: nil)) == .secondary)
}

@Test func userHiddenEntitiesAreHidden() {
    #expect(EntityCuration.tier(of: reg("light.strip", hiddenBy: "user")) == .hidden)
    #expect(EntityCuration.tier(of: reg("light.strip", hiddenBy: "integration")) == .hidden)
}

@Test func primaryDomainsComeFromTheEntityIdPrefix() {
    for id in ["light.a", "switch.a", "input_boolean.a", "cover.a", "lock.a", "climate.a",
               "scene.a", "script.a", "button.a", "input_button.a"] {
        #expect(EntityCuration.tier(of: reg(id)) == .primary, "\(id) should be primary")
    }
    #expect(EntityCuration.tier(of: reg("media_player.tv")) == .primary)
    // The prefix rule is what makes this list independent of which renderers exist: every id above
    // was already classified from its prefix while `media_player` still had no `Domain` case at
    // all, and gaining one in D.2 changed what renders, not what is curated.
    #expect(EntityCuration.tier(of: reg("fan.attic")) == .secondary)
}

@Test func rawSensorsAreDemotedNotDropped() {
    #expect(EntityCuration.tier(of: reg("sensor.kitchen_power")) == .secondary)
    #expect(EntityCuration.tier(of: reg("binary_sensor.kitchen_motion")) == .secondary)
}

@Test func unrecognisedDomainsFallBackToSecondary() {
    // Fail-safe: a domain curation has never heard of is demoted, never hidden. An entity that
    // silently renders nowhere is unfindable, which is a worse failure than one extra row in
    // room detail.
    #expect(EntityCuration.tier(of: reg("fan.ceiling")) == .secondary)
    #expect(EntityCuration.tier(of: reg("vacuum.roomba")) == .secondary)
    #expect(EntityCuration.tier(of: reg("weather.home")) == .secondary)
}

// MARK: - Device companions

@Test func deviceTelemetryCollapsesToCompanion() {
    #expect(EntityCuration.tier(of: reg("sensor.hall_motion_battery", device: "d1")) == .companion)
    #expect(EntityCuration.tier(of: reg("sensor.hall_motion_linkquality", device: "d1")) == .companion)
    #expect(EntityCuration.tier(of: reg("sensor.plug_signal_strength", device: "d1")) == .companion)
}

@Test func companionRuleNeedsAParentDeviceAndASuffixBoundary() {
    // No parent device: nothing to collapse behind, so it stays an ordinary sensor.
    #expect(EntityCuration.tier(of: reg("sensor.hall_battery", device: nil)) == .secondary)
    // "battery" must end the object id, or a battery-shaped room name would swallow real sensors.
    #expect(EntityCuration.tier(of: reg("sensor.battery_room_temperature", device: "d1")) == .secondary)
}

@Test func companionRuleNeverDemotesAControl() {
    // A control keeps its tile whatever it is named — the suffix heuristic only ever demotes
    // non-primary domains, so it can't cost the user a switch they can reach today.
    #expect(EntityCuration.tier(of: reg("switch.speaker_identify", device: "d1")) == .primary)
    #expect(EntityCuration.tier(of: reg("light.desk_battery", device: "d1")) == .primary)
}

// MARK: - Surfaces

@Test func overviewShowsControlsAndDetailAddsSensors() {
    let r = room([reg("light.ceiling"), reg("sensor.kitchen_power"), reg("binary_sensor.door"),
                  reg("sensor.hall_motion_battery", device: "d1"),
                  reg("sensor.hall_rssi", category: "diagnostic"), reg("switch.kettle", hiddenBy: "user")])
    #expect(r.overviewRefs.map(\.id) == ["light.ceiling"])
    #expect(r.detailRefs.map(\.id).sorted() == ["binary_sensor.door", "light.ceiling", "sensor.kitchen_power"])
    // Companions, diagnostics and user-hidden entities reach neither surface, but the area
    // still knows about them for the configuration sub-project's opt-in overrides.
    #expect(r.deviceRefs.count == 6)
    #expect(r.tier(of: "sensor.hall_motion_battery") == .companion)
}

@Test func disabledEntitiesNeverReachCuration() {
    // `disabled_by` is filtered structurally in the resolver (a disabled entity has no state at
    // all), so it is not re-checked in `EntityCuration`. This proves that filter still holds.
    let r = room([reg("light.ceiling"), reg("light.broken", disabledBy: "integration")])
    #expect(r.overviewRefs.map(\.id) == ["light.ceiling"])
    #expect(r.tiers["light.broken"] == nil)
}

@Test func upliftedSensorsStayOutOfBothGrids() {
    let r = room([reg("light.ceiling"), reg("sensor.temp"), reg("sensor.hum")],
                 temperature: "sensor.temp", humidity: "sensor.hum")
    #expect(r.headerSensors.map(\.entityId).sorted() == ["sensor.hum", "sensor.temp"])
    #expect(r.detailRefs.map(\.id) == ["light.ceiling"])
}

@Test func unknownEntityIdDefaultsToPrimary() {
    let r = room([reg("light.ceiling")])
    #expect(r.tier(of: "light.never_seen") == .primary)
}

// MARK: - Never empty a room that has entities

@Test func aRoomWhoseControlsAreAllDiagnosticStillShowsThem() {
    let r = room([reg("light.ceiling", category: "diagnostic"), reg("sensor.kitchen_power")])
    // The controllable entity is rescued ahead of the sensor: it is the thing the user came for.
    #expect(r.overviewRefs.map(\.id) == ["light.ceiling"])
    #expect(r.tier(of: "sensor.kitchen_power") == .secondary)
}

@Test func aSensorOnlyRoomPromotesItsSensors() {
    let r = room([reg("sensor.kitchen_power"), reg("binary_sensor.door")])
    #expect(r.overviewRefs.map(\.id).sorted() == ["binary_sensor.door", "sensor.kitchen_power"])
}

@Test func aRoomOfNothingButDeviceTelemetryPromotesItsCompanions() {
    let r = room([reg("sensor.hall_motion_battery", device: "d1"), reg("sensor.hall_motion_lqi", device: "d1")])
    #expect(r.overviewRefs.count == 2)
}

@Test func aRoomOfNothingButDiagnosticsPromotesThem() {
    let r = room([reg("sensor.hall_rssi", category: "diagnostic"), reg("sensor.hall_uptime", category: "diagnostic")])
    #expect(r.overviewRefs.count == 2)
}

@Test func rescueNeverOverridesWhatTheUserHidInHomeAssistant() {
    let r = room([reg("light.strip", hiddenBy: "user"), reg("sensor.kitchen_power")])
    #expect(r.overviewRefs.map(\.id) == ["sensor.kitchen_power"])
    #expect(r.tier(of: "light.strip") == .hidden)
}

@Test func rescueDoesNotFireWhenTheRoomAlreadyHasAControl() {
    let r = room([reg("light.ceiling"), reg("sensor.kitchen_power"), reg("sensor.hall_rssi", category: "diagnostic")])
    #expect(r.overviewRefs.map(\.id) == ["light.ceiling"])
    #expect(r.tier(of: "sensor.kitchen_power") == .secondary)
    #expect(r.tier(of: "sensor.hall_rssi") == .hidden)
}

@Test func aRoomWhoseOnlyControlTheUserHidStaysEmpty() {
    // Intentional, and pinned here so it isn't later "fixed" into overriding the user: the
    // never-empty rule exists to undo *our* heuristics, not a choice made in HA.
    let r = room([reg("light.strip", hiddenBy: "user")])
    #expect(r.overviewRefs.isEmpty)
    #expect(r.detailRefs.isEmpty)
}

@Test func anEmptyAreaStaysEmpty() {
    let r = room([])
    #expect(r.overviewRefs.isEmpty)
    #expect(EntityCuration.tiers(for: []).isEmpty)
}

// MARK: - Wire shape

@Test func entityRegistryWireDecodeCarriesCurationFields() throws {
    // Curation is only as good as the decode: `HACoding.decoder`'s `.convertFromSnakeCase` is
    // what turns `entity_category` into `entityCategory`, and if that assumption were wrong every
    // struct-literal test above would still pass while curation silently became a no-op on real
    // data (the same trap `HomeConnection.fetchInstanceConfig` documents). So decode a realistic
    // `config/entity_registry/list` element instead.
    let json = """
    [{"area_id": null, "config_entry_id": "c1", "device_id": "d1", "disabled_by": "integration",
      "entity_category": "diagnostic", "entity_id": "sensor.hall_rssi", "has_entity_name": true,
      "hidden_by": "user", "icon": null, "id": "reg1", "name": null, "original_name": "RSSI",
      "platform": "zha", "translation_key": null, "unique_id": "u1"}]
    """
    let entries = try HACoding.decoder.decode([EntityRegistryEntry].self, from: Data(json.utf8))
    let e = try #require(entries.first)
    #expect(e.entityId == "sensor.hall_rssi")
    #expect(e.deviceId == "d1")
    #expect(e.entityCategory == "diagnostic")
    #expect(e.hiddenBy == "user")
    #expect(e.disabledBy == "integration")
}
