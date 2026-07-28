import Foundation

public struct EntityState: Sendable, Equatable, Identifiable {
    public var entityId: String
    public var state: String
    public var attributes: [String: JSONValue]
    public var lastUpdated: Date
    public var id: String { entityId }
    public var domain: String { String(entityId.prefix(while: { $0 != "." })) }

    public init(entityId: String, state: String, attributes: [String: JSONValue], lastUpdated: Date) {
        self.entityId = entityId; self.state = state
        self.attributes = attributes; self.lastUpdated = lastUpdated
    }
}

public extension EntityState {
    /// The two states Home Assistant uses to say "there is no reading": `unavailable` (the device
    /// cannot be reached) and `unknown` (it can, but has not reported a value).
    ///
    /// Kept distinct from any *ordinary* state — `off` is a reading, and a surface that treats an
    /// unreachable light as an off one is telling the user something false about their home.
    static let unavailableStates: Set<String> = ["unavailable", "unknown"]

    /// Whether this entity currently has no reading at all. One definition, because the answer has
    /// to be the same everywhere it is asked: the tile's calm state, the environment pill's
    /// em-dash, and climate's on/off all used to spell these two strings out separately.
    var isUnavailable: Bool { Self.unavailableStates.contains(state) }
}
