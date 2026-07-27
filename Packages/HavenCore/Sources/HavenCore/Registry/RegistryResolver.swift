import Foundation

public enum RegistryResolver {
    static let noFloorId = "__no_floor__"
    static let unassignedAreaId = "__unassigned__"

    public static func resolve(floors: [FloorRegistryEntry], areas: [AreaRegistryEntry],
                               devices: [DeviceRegistryEntry], entities: [EntityRegistryEntry]) -> ResolvedHome {
        let deviceArea = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.areaId) })

        // area_id -> [entity_id], applying entity.areaId ?? device.areaId.
        // Disabled entities (disabled_by != nil) never enter HA's state machine — they're
        // absent from get_states/state_changed — so they'd render as permanently-inert
        // tiles. Drop them here, before they reach any area.
        var entitiesByArea: [String: [EntityRegistryEntry]] = [:]
        var registryInfo: [String: EntityRegistryInfo] = [:]
        for e in entities where e.disabledBy == nil {
            let resolvedArea = e.areaId ?? e.deviceId.flatMap { deviceArea[$0] ?? nil } ?? unassignedAreaId
            entitiesByArea[resolvedArea, default: []].append(e)
            registryInfo[e.entityId] = EntityRegistryInfo(platform: e.platform, uniqueId: e.uniqueId,
                                                          deviceId: e.deviceId)
        }

        // Curation is computed per area, not per entity, because its never-empty-a-room rescue
        // needs the whole area to decide (see `EntityCuration.tiers(for:)`).
        var areaModels = areas.map {
            let entries = entitiesByArea[$0.areaId] ?? []
            return ResolvedArea(id: $0.areaId, name: $0.name, entityIds: entries.map(\.entityId).sorted(),
                                temperatureEntityId: $0.temperatureEntityId, humidityEntityId: $0.humidityEntityId,
                                tiers: EntityCuration.tiers(for: entries))
        }
        if let orphans = entitiesByArea[unassignedAreaId], !orphans.isEmpty {
            areaModels.append(ResolvedArea(id: unassignedAreaId, name: "Unassigned",
                                           entityIds: orphans.map(\.entityId).sorted(),
                                           tiers: EntityCuration.tiers(for: orphans)))
        }

        // area_id -> floor_id, plus synthetic floor for nil
        let areaFloor = Dictionary(uniqueKeysWithValues: areas.map { ($0.areaId, $0.floorId) })
        let knownFloorIds = Set(floors.map { $0.floorId })
        var areasByFloor: [String: [ResolvedArea]] = [:]
        for a in areaModels {
            let rawFloor = a.id == unassignedAreaId ? nil : (areaFloor[a.id] ?? nil)
            let fid = (rawFloor.flatMap { knownFloorIds.contains($0) ? $0 : nil }) ?? noFloorId
            areasByFloor[fid, default: []].append(a)
        }

        // Real floors in level order, ties broken by registry order. The tiebreak is not a nicety:
        // `f.level ?? 0` collapses every floor HA left unlevelled onto 0, so ties are the ordinary
        // case rather than an edge one, and `sorted(by:)` is documented as unstable — without it two
        // unlevelled floors could swap places between two identical registry loads, which the pager
        // would show as the house rearranging itself.
        var floorModels: [ResolvedFloor] = floors.compactMap { f -> ResolvedFloor? in
            guard let list = areasByFloor[f.floorId], !list.isEmpty else { return nil }
            return ResolvedFloor(id: f.floorId, name: f.name, level: f.level ?? 0,
                                 areas: list.sorted { $0.name < $1.name })
        }
        .enumerated()
        .sorted { ($0.element.level, $0.offset) < ($1.element.level, $1.offset) }
        .map(\.element)

        // "Home" leads. It holds everything HA never filed onto a floor, which makes it the page a
        // user lands on and pages back to — the leftmost one, not the one past the top of the house.
        // Position is the array's now, not `level`'s; `Int.min` is only there so that an incidental
        // re-sort by level somewhere else would still agree with the order chosen here.
        if let noFloorAreas = areasByFloor[noFloorId], !noFloorAreas.isEmpty {
            floorModels.insert(ResolvedFloor(id: noFloorId, name: "Home", level: Int.min,
                                             areas: noFloorAreas.sorted { $0.name < $1.name }), at: 0)
        }
        return ResolvedHome(floors: floorModels, registryInfo: registryInfo)
    }
}
