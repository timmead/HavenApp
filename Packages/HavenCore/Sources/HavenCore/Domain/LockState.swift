public struct LockState: Sendable, Equatable {
    public let isLocked: Bool
    public let isJammed: Bool
    public init(_ e: EntityState) { isLocked = e.state == "locked"; isJammed = e.state == "jammed" }
}
