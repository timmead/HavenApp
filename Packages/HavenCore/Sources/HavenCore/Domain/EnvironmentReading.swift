import Foundation

/// Turns a room's nominated environment source into the text on its header pill.
///
/// Split from the views because it is the same in both places that render a pill (the room section
/// heading and the room detail toolbar), and because `value(_:state:)` doubles as the test of
/// whether a proposed nomination is worth *writing* — see `RoomEnvironmentResolver`. Keeping both
/// answers in one function is what stops "readable enough to display" and "readable enough to
/// persist" from drifting apart.
public enum EnvironmentReading {
    /// Home Assistant's two non-values. An entity reporting either has no reading, whatever its
    /// attributes still say.
    private static let nonValues: Set<String> = ["unavailable", "unknown"]

    /// The numeric reading and the unit to show it in, or `nil` when there isn't one.
    ///
    /// `nil` covers every way a reading can be missing — no state at all, `unavailable`, `unknown`,
    /// a non-numeric state, an absent attribute — because callers do the same thing for all of
    /// them: show an em-dash, and don't persist the nomination.
    public static func value(_ sensor: UpliftedSensor, state: EntityState?) -> (Double, String)? {
        guard let state, !nonValues.contains(state.state) else { return nil }
        switch sensor.source {
        case .state:
            guard let number = Double(state.state) else { return nil }
            return (number, state.attributes["unit_of_measurement"]?.asString ?? defaultUnit(sensor.role))
        case .attribute(let name):
            guard let number = state.attributes[name]?.asDouble else { return nil }
            // A climate entity states its scale in `temperature_unit`, not `unit_of_measurement`
            // (which describes nothing on a thermostat) — the same attribute `ClimateState` reads.
            // Humidity is a percentage on every integration; there is no per-entity unit for it.
            let unit = sensor.role == .temperature
                ? state.attributes["temperature_unit"]?.asString ?? defaultUnit(.temperature)
                : defaultUnit(.humidity)
            return (number, unit)
        }
    }

    /// The pill's text: a rounded value with its unit, or an em-dash.
    ///
    /// The em-dash replaces a real bug — the previous inline `state + "°"` rendered the literal
    /// string `"unavailable°"` on any sensor that dropped off. It is also what a nomination whose
    /// entity has since been removed from Home Assistant renders as: a stored nomination is
    /// authoritative and is deliberately *not* silently re-picked, so saying "no reading" is the
    /// honest answer until someone changes the nomination.
    public static func display(_ sensor: UpliftedSensor, state: EntityState?) -> String {
        guard let (number, unit) = value(sensor, state: state) else { return "—" }
        return format(number, role: sensor.role) + unit
    }

    /// Temperature keeps one decimal (21.5°C reads as a measurement; 21.53°C reads as a readout),
    /// dropping it when it is a trailing zero. Humidity is whole numbers — nobody needs a tenth of
    /// a percent of relative humidity on a room heading.
    private static func format(_ number: Double, role: UpliftedSensor.Role) -> String {
        switch role {
        case .humidity:
            return String(Int(number.rounded()))
        case .temperature:
            let rounded = (number * 10).rounded() / 10
            return rounded == rounded.rounded()
                ? String(Int(rounded.rounded()))
                : String(format: "%.1f", rounded)
        }
    }

    /// What to show when the entity declares no unit. A bare degree sign is honest about a
    /// temperature whose scale we weren't told; percent is the only thing humidity is ever in.
    private static func defaultUnit(_ role: UpliftedSensor.Role) -> String {
        role == .temperature ? "°" : "%"
    }
}
