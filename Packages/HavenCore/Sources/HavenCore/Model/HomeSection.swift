public enum SectionKind: Sendable, Equatable { case room }

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
    /// Builds the room sections for a home.
    ///
    /// - Parameter environment: each area's resolved temperature/humidity nomination, keyed by area
    ///   id — see `RoomEnvironmentResolver`. Required rather than defaulted: an omitted environment
    ///   means every room silently loses its pills, which is precisely the failure this parameter
    ///   exists to make impossible to introduce by accident.
    public static func rooms(from home: ResolvedHome,
                             environment: [String: RoomEnvironment]) -> [RoomSection] {
        home.floors.flatMap(\.areas).map { area in
            let header = environment[area.id]?.headerSensors ?? []
            // An uplifted reading is shown in the heading instead of as a tile — but only when the
            // heading has taken over the whole entity. A `.attribute` source has not: the pill
            // reads one attribute off a thermostat, and the thermostat itself is still a control
            // the room needs a tile for. Dropping it would remove the climate tile from every
            // thermostat-only room.
            let uplifted = Set(header.compactMap { sensor -> String? in
                guard case .state = sensor.source else { return nil }
                return sensor.entityId
            })
            let devices = area.entityIds.filter { !uplifted.contains($0) }.map { DeviceRef.entity($0) }
            return RoomSection(id: area.id, name: area.name, areaId: area.id, headerSensors: header,
                               deviceRefs: devices, tiers: area.tiers)
        }
    }
}
