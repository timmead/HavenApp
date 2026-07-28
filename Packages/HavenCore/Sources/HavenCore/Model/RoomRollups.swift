public struct Rollup: Sendable, Equatable {
    public enum Kind: Sendable, Hashable { case lights, covers }
    public let kind: Kind
    public let activeCount: Int
    public let total: Int
    public let targetEntityIds: [String]
}

public enum RoomRollups {
    public static func compute(entityIds: [String], states: [String: EntityState]) -> [Rollup] {
        var out: [Rollup] = []
        let lights = entityIds.filter { Domain.of($0) == .light }
        if !lights.isEmpty {
            let on = lights.filter { states[$0]?.state == "on" }
            out.append(Rollup(kind: .lights, activeCount: on.count, total: lights.count, targetEntityIds: lights))
        }
        let covers = entityIds.filter { Domain.of($0) == .cover }
        if !covers.isEmpty {
            let open = covers.filter { let s = states[$0]?.state; return s == "open" || s == "opening" }
            out.append(Rollup(kind: .covers, activeCount: open.count, total: covers.count, targetEntityIds: covers))
        }
        return out
    }
}
