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
    /// The orders the household arranged this room into, keyed by the surface each was arranged on,
    /// and absent for a surface nobody has arranged — see `TileOrder` and `refs(for:)`.
    public let orders: [HavenSurface: [String]]

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
        // **Every ref has an id, composites included**, so a shade group is dragged and ordered like
        // anything else. This used to sort composites to the end on the grounds that they carried no
        // single entity id — true when nothing constructed them, and wrong now that a composite's id
        // is its own rather than derived from its inputs.
        let ordered = TileOrder.resolve(stored: storedOrder(for: surface), present: visible.map(\.id))
        let position = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) })
        return visible.sorted { (position[$0.id] ?? 0) < (position[$1.id] ?? 0) }
    }

    /// The list `surface`'s arrangement is resolved against: **this surface's own, then the other
    /// surface's, then none** — design decision 9.
    ///
    /// **Resolved on every read rather than copied on first use**, and the difference is the whole
    /// behaviour. A surface nobody has arranged does not get a snapshot of its sibling; it *follows*
    /// it, so arranging the dashboard keeps rearranging an untouched room-detail view too. The two
    /// diverge at the moment somebody drags on the second surface, which writes what it resolved and
    /// stops following. Copying instead would fork them on first render, which is a fork nobody
    /// asked for and nobody can see happening.
    ///
    /// Falling back to the *other* surface rather than straight to the default is what makes a room
    /// somebody arranged on the dashboard look arranged when they open it. `TileOrder.resolve` then
    /// does the rest untouched: ids the borrowed list does not mention — the demoted sensors that
    /// exist only in room detail — are newcomers appended in `defaultOrder`, which is rule 2 doing
    /// exactly the job it was written for.
    ///
    /// The `other` switch is meaningful **only because there are exactly two surfaces**, and is
    /// exhaustive with no `default` so a third has to decide here what it borrows from rather than
    /// inheriting an answer that would be wrong.
    private func storedOrder(for surface: HavenSurface) -> [String] {
        if let own = orders[surface], !own.isEmpty { return own }
        let other: HavenSurface = switch surface {
        case .overview: .roomDetail
        case .roomDetail: .overview
        }
        return orders[other] ?? []
    }

    private func visibleRefs(for surface: HavenSurface) -> [DeviceRef] {
        deviceRefs.filter { ref in
            // **A composite is shown unless the household removed it.** It has no curation tier of
            // its own — curation ranks Home Assistant's entities, and a composite is Haven's — so it
            // is a curated unit by construction: somebody made it deliberately. Its membership
            // override still applies, so removing one from a surface works like removing anything.
            guard case .entity(let id) = ref else {
                return overrides[ref.id]?[surface] != .hidden
            }
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
    /// - Parameter orders: each room's arranged tile orders, keyed by area id and then by the
    ///   surface each was arranged on — see `TileOrder` and `RoomSection.refs(for:)`. Required for
    ///   the same reason as the two below: an omitted map silently discards every arrangement the
    ///   household has made.
    /// - Parameter overrides: each entity's per-surface membership — see `SurfaceMembership`.
    ///   Required for the same reason, and the failure is worse: an omitted map means every removal
    ///   the household has ever made silently reverts, and nothing at the call site would say so.
    /// - Parameter devices: the household's composites, by id — see `DashboardDocument.devices`.
    ///   Required like the maps above: omitting it silently drops every shade group in the home and
    ///   renders its members as loose tiles, which looks like the feature was never built.
    public static func rooms(from home: ResolvedHome,
                             environment: [String: RoomEnvironment],
                             devices: [String: DashboardDocument.StoredDevice],
                             overrides: [String: [HavenSurface: SurfaceMembership]],
                             orders: [String: [HavenSurface: [String]]]) -> [RoomSection] {
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
            // Composites first, then the entities none of them consumed.
            //
            // **An entity a composite uses does not also render alone**, or a shade group and its
            // three shades are four tiles. Scoped to *this* area: a shade moved to another room in
            // Home Assistant still gets a tile there, the same precedence `RegistryResolver` and the
            // curation rules already apply.
            let composites = devices
                .filter { $0.value.areaId == area.id }
                .sorted { $0.key < $1.key }
                .map { DeviceRef.composite(id: $0.key, type: $0.value.type, inputs: $0.value.inputs) }
            let consumed = Set(composites.flatMap(\.entityIds))
            let plain = area.entityIds
                .filter { !uplifted.contains($0) && !consumed.contains($0) }
                .map { DeviceRef.entity($0) }
            let devices = composites + plain
            return RoomSection(id: area.id, name: area.name, areaId: area.id, headerSensors: header,
                               deviceRefs: devices, tiers: area.tiers, overrides: overrides,
                               orders: orders[area.id] ?? [:])
        }
    }
}
