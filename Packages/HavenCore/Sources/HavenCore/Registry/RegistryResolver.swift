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
        var entitiesByArea: [String: [String]] = [:]
        for e in entities where e.disabledBy == nil {
            let resolvedArea = e.areaId ?? e.deviceId.flatMap { deviceArea[$0] ?? nil } ?? unassignedAreaId
            entitiesByArea[resolvedArea, default: []].append(e.entityId)
        }

        var areaModels = areas.map {
            ResolvedArea(id: $0.areaId, name: $0.name, entityIds: (entitiesByArea[$0.areaId] ?? []).sorted(),
                         temperatureEntityId: $0.temperatureEntityId, humidityEntityId: $0.humidityEntityId)
        }
        if let orphans = entitiesByArea[unassignedAreaId], !orphans.isEmpty {
            areaModels.append(ResolvedArea(id: unassignedAreaId, name: "Unassigned", entityIds: orphans.sorted()))
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

        var floorModels: [ResolvedFloor] = floors.compactMap { f in
            guard let list = areasByFloor[f.floorId], !list.isEmpty else { return nil }
            return ResolvedFloor(id: f.floorId, name: f.name, level: f.level ?? 0,
                                 areas: list.sorted { $0.name < $1.name })
        }
        if let noFloorAreas = areasByFloor[noFloorId], !noFloorAreas.isEmpty {
            floorModels.append(ResolvedFloor(id: noFloorId, name: "Home", level: Int.max,
                                             areas: noFloorAreas.sorted { $0.name < $1.name }))
        }
        return ResolvedHome(floors: floorModels.sorted { $0.level < $1.level })
    }
}
