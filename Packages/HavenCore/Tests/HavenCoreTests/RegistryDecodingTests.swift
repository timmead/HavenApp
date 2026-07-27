import Foundation
import Testing
@testable import HavenCore

/// Decodes a realistic `config/entity_registry/list` row through the exact decoder
/// `HomeConnection.decodeList` uses.
///
/// This is the test that would catch a `keyDecodingStrategy` regression: `platform` has no
/// underscore to mis-convert, so a slip there would show up only on `unique_id` — decoding both
/// to nil and silently disabling `VendorHandoff` on real data while every struct-literal test
/// elsewhere (which never round-trips through `HACoding.decoder`) stayed green.
///
/// The payload below is `EntityRegistryEntry.as_partial_dict` from Home Assistant's own source,
/// which is what `websocket_list_entities` serialises. An earlier version of this fixture also
/// carried `device_class`, `original_device_class`, `unit_of_measurement`, `capabilities` and
/// `supported_features` — **none of which this command sends**; they live only in `extended_dict`,
/// used by `config/entity_registry/get`. Those keys decoded to nothing (the struct declares none of
/// them), so the fixture stayed green while quietly asserting a wire shape that does not exist —
/// and it was later read as evidence that device classes were available from the registry. They are
/// not, which is why `RoomEnvironmentResolver` takes `device_class` from live entity state instead.
/// Keep this list matching `as_partial_dict`.
@Test func entityRegistryEntryDecodesPlatformAndUniqueIdFromRealisticPayload() throws {
    let json = """
    [
      {
        "entity_id": "camera.front_door",
        "unique_id": "63f1a2b3c4d5e6f7a8b9c0d1",
        "platform": "unifiprotect",
        "id": "01JENTITYREGISTRYID000001",
        "config_entry_id": "01JABCXYZDEADBEEF0000001",
        "config_subentry_id": null,
        "created_at": 1753600000.0,
        "modified_at": 1753600000.0,
        "categories": {},
        "labels": [],
        "device_id": "dev_front_door",
        "area_id": "area_porch",
        "disabled_by": null,
        "hidden_by": null,
        "entity_category": null,
        "name": null,
        "icon": null,
        "original_name": "Front Door",
        "translation_key": null,
        "has_entity_name": true,
        "options": {}
      },
      {
        "entity_id": "media_player.living_room_sonos",
        "unique_id": "RINCON_5CAAFD1234560123401",
        "platform": "sonos",
        "id": "01JENTITYREGISTRYID000002",
        "config_entry_id": "01JABCXYZDEADBEEF0000002",
        "config_subentry_id": null,
        "created_at": 1753600000.0,
        "modified_at": 1753600000.0,
        "categories": {},
        "labels": [],
        "device_id": "dev_living_room_sonos",
        "area_id": "area_living_room",
        "disabled_by": null,
        "hidden_by": null,
        "entity_category": null,
        "name": null,
        "icon": null,
        "original_name": "Living Room",
        "translation_key": null,
        "has_entity_name": true,
        "options": {}
      }
    ]
    """.data(using: .utf8)!

    let entries = try HACoding.decoder.decode([EntityRegistryEntry].self, from: json)
    #expect(entries.count == 2)

    let camera = try #require(entries.first { $0.entityId == "camera.front_door" })
    #expect(camera.platform == "unifiprotect")
    #expect(camera.uniqueId == "63f1a2b3c4d5e6f7a8b9c0d1")
    // A pre-existing snake_case field, asserted alongside the two new ones: this is what actually
    // exercises `keyDecodingStrategy`, rather than something a hardcoded `CodingKeys` for just
    // `platform`/`uniqueId` could pass while every other field silently broke.
    #expect(camera.areaId == "area_porch")
    #expect(camera.disabledBy == nil)

    let sonos = try #require(entries.first { $0.entityId == "media_player.living_room_sonos" })
    #expect(sonos.platform == "sonos")
    #expect(sonos.uniqueId == "RINCON_5CAAFD1234560123401")
}

/// `RegistryResolver.resolve` must carry `platform`/`uniqueId` through into `ResolvedHome`,
/// keyed by entity id, for a renderer that only has an entity id in hand (a camera or media
/// player modal) to look up — see `EntityRegistryInfo`.
@Test func resolverThreadsPlatformAndUniqueIdIntoRegistryInfo() {
    let areas = [AreaRegistryEntry(areaId: "a", name: "Porch", floorId: nil, icon: nil,
                                   temperatureEntityId: nil, humidityEntityId: nil)]
    let entities = [
        EntityRegistryEntry(entityId: "camera.front_door", areaId: "a", deviceId: nil, name: nil,
                            platform: "unifiprotect", uniqueId: "abc123"),
        EntityRegistryEntry(entityId: "media_player.sonos", areaId: "a", deviceId: nil, name: nil,
                            platform: "sonos", uniqueId: nil),
    ]
    let home = RegistryResolver.resolve(floors: [], areas: areas, devices: [], entities: entities)
    #expect(home.registryInfo["camera.front_door"]?.platform == "unifiprotect")
    #expect(home.registryInfo["camera.front_door"]?.uniqueId == "abc123")
    #expect(home.registryInfo["media_player.sonos"]?.platform == "sonos")
    #expect(home.registryInfo["media_player.sonos"]?.uniqueId == nil)
}

/// `device_id` rides along for the same reason, and one more: `CameraEvents` joins a camera to its
/// own motion/doorbell sensors on it. Without it that join falls back to matching entity-id stems,
/// where two cameras sharing a name stem adopt each other's sensors — an "Events" card making a
/// false statement about the user's home.
@Test func resolverThreadsDeviceIdIntoRegistryInfo() {
    let entities = [
        EntityRegistryEntry(entityId: "camera.front_door", areaId: "a", deviceId: "dev-1", name: nil,
                            platform: "unifiprotect", uniqueId: "abc123"),
        EntityRegistryEntry(entityId: "binary_sensor.front_door_motion", areaId: "a", deviceId: "dev-1",
                            name: nil, platform: "unifiprotect", uniqueId: "abc123_motion"),
        EntityRegistryEntry(entityId: "light.deviceless", areaId: "a", deviceId: nil, name: nil),
    ]
    let home = RegistryResolver.resolve(floors: [], areas: [], devices: [], entities: entities)
    #expect(home.registryInfo["camera.front_door"]?.deviceId == "dev-1")
    #expect(home.registryInfo["binary_sensor.front_door_motion"]?.deviceId == "dev-1")
    #expect(home.registryInfo["light.deviceless"]?.deviceId == nil)
}

/// A disabled entity never enters HA's state machine and has no renderer to hand this to, so it
/// must not linger in `registryInfo` either — mirroring the same filter `RegistryResolver`
/// already applies when bucketing entities into areas.
@Test func disabledEntityExcludedFromRegistryInfo() {
    let entities = [
        EntityRegistryEntry(entityId: "camera.disabled", areaId: nil, deviceId: nil, name: nil,
                            disabledBy: "user", platform: "unifiprotect", uniqueId: "xyz"),
    ]
    let home = RegistryResolver.resolve(floors: [], areas: [], devices: [], entities: entities)
    #expect(home.registryInfo["camera.disabled"] == nil)
}
