import Foundation

public struct SensorState: Sendable, Equatable {
    public let value: String
    public let unit: String?
    public let deviceClass: String?
    public var numericValue: Double? { Double(value) }
    public var isNumeric: Bool { numericValue != nil }
    public init(_ e: EntityState) {
        value = e.state
        unit = e.attributes["unit_of_measurement"]?.asString
        deviceClass = e.deviceClass
    }
}
