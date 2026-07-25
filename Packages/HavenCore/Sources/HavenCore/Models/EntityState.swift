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
