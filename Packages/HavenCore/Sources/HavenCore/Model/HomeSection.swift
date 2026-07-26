public enum SectionKind: Sendable, Equatable { case room }

public struct UpliftedSensor: Sendable, Equatable {
    public enum Role: Sendable, Equatable { case temperature, humidity }
    public let role: Role
    public let entityId: String
}

public struct RoomSection: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let kind: SectionKind = .room
    public let areaId: String
    public let headerSensors: [UpliftedSensor]
    /// Every entity in the area (minus the uplifted header sensors), whatever its curation
    /// tier. Views render `overviewRefs`/`detailRefs` rather than this — see `CurationTier`.
    public let deviceRefs: [DeviceRef]
    public let tiers: [String: CurationTier]

    public func tier(of entityId: String) -> CurationTier { tiers[entityId] ?? .primary }

    /// What the room's overview grid shows: controls only. Everything else is one tap away in
    /// room detail, which is the whole point of the tiering — a room section is a summary, not
    /// an inventory.
    public var overviewRefs: [DeviceRef] { refs(in: [.primary]) }

    /// What room detail shows: the overview's controls plus the demoted sensors. `.companion`
    /// telemetry stays out — it belongs behind its parent device, not in the room's sensor grid.
    public var detailRefs: [DeviceRef] { refs(in: [.primary, .secondary]) }

    private func refs(in allowed: Set<CurationTier>) -> [DeviceRef] {
        deviceRefs.filter { ref in
            // A composite carries no single entity id, so no tier — nothing constructs them yet
            // (see `DeviceRef`), and when something does it will be a curated unit by definition.
            guard case .entity(let id) = ref else { return true }
            return allowed.contains(tier(of: id))
        }
    }
}

public enum SectionBuilder {
    public static func rooms(from home: ResolvedHome) -> [RoomSection] {
        home.floors.flatMap(\.areas).map { area in
            var header: [UpliftedSensor] = []
            if let t = area.temperatureEntityId { header.append(.init(role: .temperature, entityId: t)) }
            if let h = area.humidityEntityId { header.append(.init(role: .humidity, entityId: h)) }
            let uplifted = Set(header.map(\.entityId))
            let devices = area.entityIds.filter { !uplifted.contains($0) }.map { DeviceRef.entity($0) }
            return RoomSection(id: area.id, name: area.name, areaId: area.id, headerSensors: header,
                               deviceRefs: devices, tiers: area.tiers)
        }
    }
}
