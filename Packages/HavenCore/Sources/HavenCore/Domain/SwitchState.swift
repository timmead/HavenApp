public struct SwitchState: Sendable, Equatable {
    public let isOn: Bool
    public init(_ e: EntityState) { isOn = e.state == "on" }
}
