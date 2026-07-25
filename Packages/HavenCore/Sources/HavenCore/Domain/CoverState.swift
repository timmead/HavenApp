public struct CoverState: Sendable, Equatable {
    public let isOpen: Bool
    public let positionPercent: Int?
    public let supportsPosition: Bool
    public init(_ e: EntityState) {
        isOpen = e.state == "open" || e.state == "opening"
        positionPercent = e.attributes["current_position"]?.asInt
        supportsPosition = e.attributes["current_position"] != nil
    }
}
