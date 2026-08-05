/// The registry fields a renderer needs to identify an entity's owning integration and device,
/// without holding the full `EntityRegistryEntry` (area/device wiring, curation fields, …) that
/// produced it. `platform` is the integration domain (`"unifiprotect"`, `"sonos"`); `uniqueId` is
/// that integration's own identifier for the device. See `VendorHandoff` for what these are used
/// for and what is and isn't verified about them.
public struct EntityRegistryInfo: Sendable, Equatable {
    public let platform: String?
    public let uniqueId: String?
    /// HA's `device_id` — which physical device this entity belongs to, or `nil` for the many
    /// integrations that create entities without one.
    ///
    /// Carried here so the camera modal's **Events** card can join a camera to its own motion and
    /// doorbell sensors on the device rather than on their names: two cameras sharing a name stem
    /// (`camera.front`, `camera.front_gate`) would otherwise adopt each other's sensors, and a card
    /// headed "Events" listing another camera's motion is a false statement about the user's home.
    /// See `CameraEvents`, which uses this as the strong rung of its ladder and falls back to stem
    /// matching only when it is absent.
    public let deviceId: String?
    public init(platform: String?, uniqueId: String?, deviceId: String? = nil) {
        self.platform = platform; self.uniqueId = uniqueId; self.deviceId = deviceId
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
    /// Each device's display name, keyed by `device_id` — Home Assistant's own precedence,
    /// `name_by_user` before `name`.
    ///
    /// Carried so a picker can group a device's entities under the device: a UniFi camera contributes
    /// eight `binary_sensor.*_detected` entities, and eight top-level rows for one physical camera is
    /// what made the add-tile list unusable. The resolver already reads the device registry for area
    /// inheritance and was discarding the names.
    ///
    /// Defaulted, unlike `SectionBuilder`'s required parameters: an absent name costs a group its
    /// heading and nothing else, where an absent membership map would silently revert a household's
    /// edits.
    public var deviceNames: [String: String]
    public init(floors: [ResolvedFloor], registryInfo: [String: EntityRegistryInfo] = [:],
                deviceNames: [String: String] = [:]) {
        self.floors = floors
        self.registryInfo = registryInfo
        self.deviceNames = deviceNames
    }
}
extension ResolvedHome {
    /// Every entity in the area that holds `entityId` — the pool a shade group's followers come
    /// from, since grouping shades Home Assistant considers unrelated is the entire point.
    ///
    /// Sorted, so a picker does not reshuffle between openings; the same rule `addableEntityIds`
    /// follows.
    public func areaEntityIds(containing entityId: String) -> [String] {
        floors.flatMap(\.areas)
            .first { $0.entityIds.contains(entityId) }?
            .entityIds.sorted() ?? []
    }

    /// The other entities on the same physical device — the companions a role could be bound to.
    ///
    /// Joined on `device_id` rather than on names, which is how a garage opener finds *its own*
    /// limit sensors: two devices sharing a name stem would otherwise adopt each other's, the same
    /// trap `EntityRegistryInfo.deviceId` exists to keep the camera events card out of.
    ///
    /// **An empty `device_id` is not a device.** Home Assistant reports one for the many
    /// integrations that create entities without a device, so treating it as an id would make
    /// every such entity a sibling of every other — a picker offering the whole home. The test for
    /// this needs *two* device-less entities to bite: with only one in the fixture, dropping this
    /// guard still returns nothing and the test passes while proving nothing.
    public func siblingEntityIds(of entityId: String) -> [String] {
        guard let deviceId = registryInfo[entityId]?.deviceId, !deviceId.isEmpty else {
            return []
        }
        return registryInfo
            .filter { $0.key != entityId && $0.value.deviceId == deviceId }
            .keys
            .sorted()
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
