import Foundation

public struct BinarySensorState: Sendable, Equatable {
    public let isActive: Bool
    public let deviceClass: String?
    public init(_ e: EntityState) { isActive = e.state == "on"; deviceClass = e.deviceClass }
}
