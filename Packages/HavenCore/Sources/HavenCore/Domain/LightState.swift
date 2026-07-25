import Foundation
public struct LightState: Sendable, Equatable {
    public let isOn: Bool
    public let brightnessPercent: Int?
    public let supportsBrightness: Bool
    public let supportsColorTemp: Bool
    public init(_ e: EntityState) {
        isOn = e.state == "on"
        if let b = e.attributes["brightness"]?.asInt { brightnessPercent = Int((Double(b) / 255.0 * 100).rounded()) }
        else { brightnessPercent = nil }
        let modes = (e.attributes["supported_color_modes"]?.asArray ?? []).compactMap { $0.asString }
        supportsBrightness = e.attributes["brightness"] != nil || modes.contains { $0 != "onoff" }
        supportsColorTemp = modes.contains("color_temp")
    }
}
