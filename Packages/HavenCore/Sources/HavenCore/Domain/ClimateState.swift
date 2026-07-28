import Foundation
public struct ClimateState: Sendable, Equatable {
    public let isOn: Bool
    public let currentTemp: Double?
    public let targetTemp: Double?
    public let hvacMode: String
    public let modes: [String]
    public let fanMode: String?
    public let fanModes: [String]
    public let unit: String
    public init(_ e: EntityState) {
        hvacMode = e.state
        isOn = !e.isUnavailable && e.state != "off"
        currentTemp = e.attributes["current_temperature"]?.asDouble
        targetTemp = e.attributes["temperature"]?.asDouble
        modes = (e.attributes["hvac_modes"]?.asArray ?? []).compactMap { $0.asString }
        fanMode = e.attributes["fan_mode"]?.asString
        fanModes = (e.attributes["fan_modes"]?.asArray ?? []).compactMap { $0.asString }
        unit = e.attributes["temperature_unit"]?.asString ?? "°"
    }
}
