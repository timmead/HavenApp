import Foundation

public struct FloorRegistryEntry: Codable, Sendable {
    public let floorId: String; public let name: String; public let level: Int?; public let icon: String?
    public init(floorId: String, name: String, level: Int?, icon: String?) {
        self.floorId = floorId; self.name = name; self.level = level; self.icon = icon
    }
}
public struct AreaRegistryEntry: Codable, Sendable {
    public let areaId: String; public let name: String; public let floorId: String?; public let icon: String?
    public let temperatureEntityId: String?; public let humidityEntityId: String?
    public init(areaId: String, name: String, floorId: String?, icon: String?,
                temperatureEntityId: String?, humidityEntityId: String?) {
        self.areaId = areaId; self.name = name; self.floorId = floorId; self.icon = icon
        self.temperatureEntityId = temperatureEntityId; self.humidityEntityId = humidityEntityId
    }
}
public struct DeviceRegistryEntry: Codable, Sendable {
    public let id: String; public let areaId: String?; public let name: String?; public let nameByUser: String?
    public init(id: String, areaId: String?, name: String?, nameByUser: String?) {
        self.id = id; self.areaId = areaId; self.name = name; self.nameByUser = nameByUser
    }
}
public struct EntityRegistryEntry: Codable, Sendable {
    public let entityId: String; public let areaId: String?; public let deviceId: String?; public let name: String?
    /// HA's `disabled_by` (e.g. "user", "integration") — non-nil means the entity is disabled
    /// and never enters HA's state machine (absent from `get_states`/`state_changed`).
    /// `RegistryResolver.resolve` filters these out before they reach any area.
    public let disabledBy: String?
    /// HA's `entity_category` — `"config"` or `"diagnostic"` (the only two HA defines), or nil
    /// for a normal entity. Both mark an entity as a device *setting* or *telemetry* rather than
    /// something you control, which is why `EntityCuration` hides them.
    public let entityCategory: String?
    /// HA's `hidden_by` (e.g. "user", "integration") — non-nil means the entity is hidden in
    /// HA's own UI. Unlike `disabledBy` it still has state, so it is a curation decision
    /// (`CurationTier.hidden`), not a structural one, and it is never overridden by curation's
    /// never-empty-a-room rescue: hiding it was an explicit choice made in HA.
    public let hiddenBy: String?
    /// HA's `platform` — the integration domain that owns this entity (`"unifiprotect"`,
    /// `"sonos"`, `"hue"`, …). Verified present on every row of `config/entity_registry/list`
    /// against Home Assistant's source. This is how `VendorHandoff` identifies a device's vendor
    /// without guessing from its name or manufacturer string.
    public let platform: String?
    /// HA's `unique_id` for this entity, as assigned by its integration. Also verified present on
    /// every row of `config/entity_registry/list`. Format is entirely up to the owning
    /// integration — see `VendorHandoff`'s doc comment for why this can't be assumed to match a
    /// vendor app's own device identifier.
    public let uniqueId: String?
    public init(entityId: String, areaId: String?, deviceId: String?, name: String?, disabledBy: String? = nil,
                entityCategory: String? = nil, hiddenBy: String? = nil, platform: String? = nil,
                uniqueId: String? = nil) {
        self.entityId = entityId; self.areaId = areaId; self.deviceId = deviceId; self.name = name
        self.disabledBy = disabledBy; self.entityCategory = entityCategory; self.hiddenBy = hiddenBy
        self.platform = platform; self.uniqueId = uniqueId
    }
}
