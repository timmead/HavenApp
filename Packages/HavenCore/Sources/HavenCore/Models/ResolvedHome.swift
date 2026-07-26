/// The registry fields a renderer needs to identify an entity's owning integration and device,
/// without holding the full `EntityRegistryEntry` (area/device wiring, curation fields, …) that
/// produced it. `platform` is the integration domain (`"unifiprotect"`, `"sonos"`); `uniqueId` is
/// that integration's own identifier for the device. See `VendorHandoff` for what these are used
/// for and what is and isn't verified about them.
public struct EntityRegistryInfo: Sendable, Equatable {
    public let platform: String?
    public let uniqueId: String?
    public init(platform: String?, uniqueId: String?) {
        self.platform = platform; self.uniqueId = uniqueId
    }
}

public struct ResolvedHome: Sendable, Equatable {
    public var floors: [ResolvedFloor]
    /// Every enabled entity's registry info, keyed by entity id — flat and area-independent
    /// because a renderer holding just an entity id (a camera or media player modal) has no
    /// reason to also carry its area to look this up. Filtered to `disabledBy == nil` entities
    /// only, matching `RegistryResolver`'s existing filter: a disabled entity never reaches the
    /// state machine, so it has no renderer to hand this to in the first place.
    public var registryInfo: [String: EntityRegistryInfo]
    public init(floors: [ResolvedFloor], registryInfo: [String: EntityRegistryInfo] = [:]) {
        self.floors = floors
        self.registryInfo = registryInfo
    }
}
public struct ResolvedFloor: Sendable, Equatable, Identifiable {
    public let id: String; public let name: String; public let level: Int; public var areas: [ResolvedArea]
    public init(id: String, name: String, level: Int, areas: [ResolvedArea]) {
        self.id = id; self.name = name; self.level = level; self.areas = areas
    }
}
public struct ResolvedArea: Sendable, Equatable, Identifiable {
    public let id: String; public let name: String; public var entityIds: [String]
    public let temperatureEntityId: String?; public let humidityEntityId: String?
    /// Curation tier per entity id (see `EntityCuration`). `entityIds` deliberately still holds
    /// *every* entity in the area, tier included — the structure is what HA says it is, and each
    /// surface decides which tiers it renders. That also keeps the hidden set available for the
    /// configuration sub-project's opt-in overrides without a second registry pass.
    public var tiers: [String: CurationTier]
    public init(id: String, name: String, entityIds: [String],
                temperatureEntityId: String? = nil, humidityEntityId: String? = nil,
                tiers: [String: CurationTier] = [:]) {
        self.id = id; self.name = name; self.entityIds = entityIds
        self.temperatureEntityId = temperatureEntityId; self.humidityEntityId = humidityEntityId
        self.tiers = tiers
    }
    /// An unclassified id falls back to `.primary`: curation must never hide something it
    /// doesn't recognise, only demote things it does.
    public func tier(of entityId: String) -> CurationTier { tiers[entityId] ?? .primary }
}
