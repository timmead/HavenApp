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
    public init(entityId: String, areaId: String?, deviceId: String?, name: String?, disabledBy: String? = nil) {
        self.entityId = entityId; self.areaId = areaId; self.deviceId = deviceId; self.name = name
        self.disabledBy = disabledBy
    }
}
