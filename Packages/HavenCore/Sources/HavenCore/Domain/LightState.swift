import Foundation
public struct LightState: Sendable, Equatable {
    public let isOn: Bool
    public let brightnessPercent: Int?
    public let supportsBrightness: Bool
    public let supportsColorTemp: Bool
    public let colorTempKelvin: Int?
    public let minColorTempKelvin: Int?
    public let maxColorTempKelvin: Int?
    public init(_ e: EntityState) {
        isOn = e.state == "on"
        if let b = e.attributes["brightness"]?.asInt { brightnessPercent = Int((Double(b) / 255.0 * 100).rounded()) }
        else { brightnessPercent = nil }
        let modes = (e.attributes["supported_color_modes"]?.asArray ?? []).compactMap { $0.asString }
        supportsBrightness = e.attributes["brightness"] != nil || modes.contains { $0 != "onoff" }
        supportsColorTemp = modes.contains("color_temp")
        colorTempKelvin = e.attributes["color_temp_kelvin"]?.asInt
        minColorTempKelvin = e.attributes["min_color_temp_kelvin"]?.asInt
        maxColorTempKelvin = e.attributes["max_color_temp_kelvin"]?.asInt
    }

    /// The device's own supported kelvin range, when it has reported well-formed bounds.
    /// `nil` if either bound is missing or degenerate — callers must not fall back to a
    /// hardcoded range, since lights differ and an out-of-range command is silently
    /// clamped by HA rather than rejected, so a wrong guess would fail invisibly.
    public var colorTempRange: ClosedRange<Int>? {
        guard let lo = minColorTempKelvin, let hi = maxColorTempKelvin, lo < hi else { return nil }
        return lo...hi
    }
}
