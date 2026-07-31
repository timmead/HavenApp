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
    /// The household's decisions about which surfaces show which of these entities, keyed by entity
    /// id — read from the dashboard document, and absent for nearly everything. See
    /// `SurfaceMembership`.
    public let overrides: [String: [HavenSurface: SurfaceMembership]]
    /// The order the household arranged this room into, or empty when nobody has — see `TileOrder`.
    public let order: [String]

    public func tier(of entityId: String) -> CurationTier { tiers[entityId] ?? .primary }

    /// What `surface` shows.
    ///
    /// **One method taking a surface, rather than the `overviewRefs`/`detailRefs` pair this
    /// replaces.** That pair had the tier sets hard-coded in two places, and a user's per-surface
    /// decision has to be applied at both — two places to apply one rule is one place to forget it.
    /// The rule itself is `SurfaceMembership.shows`, in one function with the whole matrix under
    /// test.
    /// What `surface` shows, **in the order it shows it**.
    ///
    /// Ordering happens here rather than in a view so a caller cannot forget to apply it — the same
    /// argument that collapsed `overviewRefs`/`detailRefs` into this one method when the membership
    /// rule had to reach both.
    public func refs(for surface: HavenSurface) -> [DeviceRef] {
        let visible = visibleRefs(for: surface)
        let ids = visible.compactMap { ref -> String? in
            guard case .entity(let id) = ref else { return nil }
            return id
        }
        let ordered = TileOrder.resolve(stored: order, present: ids)
        let position = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) })
        // A composite carries no single entity id and so has no position; nothing constructs them
        // yet, and when something does it will be an ordered unit by definition. Until then they
        // keep the order they arrived in, after everything that *can* be ordered.
        return visible.sorted { a, b in
            switch (a, b) {
            case let (.entity(x), .entity(y)): return (position[x] ?? 0) < (position[y] ?? 0)
            case (.entity, _): return true
            default: return false
            }
        }
    }

    private func visibleRefs(for surface: HavenSurface) -> [DeviceRef] {
        deviceRefs.filter { ref in
            // A composite carries no single entity id, so no tier and no membership — nothing
            // constructs them yet (see `DeviceRef`), and when something does it will be a curated
            // unit by definition.
            guard case .entity(let id) = ref else { return true }
            return SurfaceMembership.shows(tier: tier(of: id), on: surface,
                                           override: overrides[id]?[surface])
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
    /// - Parameter orders: each room's arranged tile order, keyed by area id — see `TileOrder`.
    ///   Required for the same reason as the two below: an omitted map silently discards every
    ///   arrangement the household has made.
    /// - Parameter overrides: each entity's per-surface membership — see `SurfaceMembership`.
    ///   Required for the same reason, and the failure is worse: an omitted map means every removal
    ///   the household has ever made silently reverts, and nothing at the call site would say so.
    public static func rooms(from home: ResolvedHome,
                             environment: [String: RoomEnvironment],
                             overrides: [String: [HavenSurface: SurfaceMembership]],
                             orders: [String: [String]]) -> [RoomSection] {
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
                               deviceRefs: devices, tiers: area.tiers, overrides: overrides,
                               order: orders[area.id] ?? [])
        }
    }
}
