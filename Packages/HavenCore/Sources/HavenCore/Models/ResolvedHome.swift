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
    public init(id: String, name: String, entityIds: [String]) {
        self.id = id; self.name = name; self.entityIds = entityIds
    }
}
