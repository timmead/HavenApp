public struct ResolvedHome: Sendable, Equatable {
    public var floors: [ResolvedFloor]
    public init(floors: [ResolvedFloor]) { self.floors = floors }
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
