import Foundation

/// Turns a room's nominated environment source into the text on its header pill.
///
/// Split from the views because it is the same in both places that render a pill (the room section
/// heading and the room detail toolbar), and because `value(_:state:)` doubles as the test of
/// whether a proposed nomination is worth *writing* — see `RoomEnvironmentResolver`. Keeping both
/// answers in one function is what stops "readable enough to display" and "readable enough to
/// persist" from drifting apart.
public enum EnvironmentReading {
    /// The numeric reading and the unit to show it in, or `nil` when there isn't one.
    ///
    /// `nil` covers every way a reading can be missing — no state at all, `unavailable`, `unknown`,
    /// a non-numeric state, an absent attribute — because callers do the same thing for all of
    /// them: show an em-dash, and don't persist the nomination.
    public static func value(_ sensor: UpliftedSensor, state: EntityState?) -> (Double, String)? {
        guard let state, !state.isUnavailable else { return nil }
        let reading: (number: Double, unit: String)?
        switch sensor.source {
        case .state:
            reading = Double(state.state).map { ($0, state.attributes["unit_of_measurement"]?.asString ?? defaultUnit(sensor.role)) }
        case .attribute(let name):
            // A climate entity states its scale in `temperature_unit`, not `unit_of_measurement`
            // (which describes nothing on a thermostat) — the same attribute `ClimateState` reads.
            // Humidity is a percentage on every integration; there is no per-entity unit for it.
            let unit = sensor.role == .temperature
                ? state.attributes["temperature_unit"]?.asString ?? defaultUnit(.temperature)
                : defaultUnit(.humidity)
            reading = state.attributes[name]?.asDouble.map { ($0, unit) }
        }
        // A single guard after the switch, covering both paths, rather than two: Home Assistant's
        // two non-finite states — `"nan"` and `"inf"`/`"-inf"`/`"infinity"` — all parse as valid
        // `Double`s in Swift, unlike every other non-reading (those are already screened above, or
        // fail to parse at all). Left unguarded, `format` traps on `Int(inf.rounded())` and renders
        // the literal string `"nan°C"` — and `HomeStore.resolveEnvironment`'s `isReadable` guard,
        // which is just `value(...) != nil`, would judge a NaN sensor readable and persist its
        // nomination into shared config permanently. The repo's history parsers already apply this
        // same `isFinite` check (see `HistoryParsing.fromHistory`); this restores that consistency
        // rather than inventing a new rule. The attribute path cannot carry NaN over JSON today, but
        // guarding it too costs nothing and means the invariant doesn't depend on that staying true.
        guard let (number, unit) = reading, number.isFinite else { return nil }
        return (number, unit)
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
        return format(number, role: sensor.role, unit: unit)
    }

    /// The one place a temperature or humidity number becomes text — the pill and the room history
    /// scrub readout both go through this, so there is exactly one definition of how it's written.
    /// The scrub readout used to hand-roll its own `String(format: "%.1f")` and a hardcoded `"°"`,
    /// which is honest for Celsius and wrong the moment a home reports Fahrenheit: the pill would
    /// read `71.6°F` and the readout one row below would read `71.6°`, agreeing on the number and
    /// disagreeing about what it means.
    ///
    /// Temperature keeps one decimal (21.5°C reads as a measurement; 21.53°C reads as a readout),
    /// dropping it when it is a trailing zero. Humidity is whole numbers — nobody needs a tenth of
    /// a percent of relative humidity on a room heading.
    public static func format(_ number: Double, role: UpliftedSensor.Role, unit: String) -> String {
        switch role {
        case .humidity:
            return String(Int(number.rounded())) + unit
        case .temperature:
            let rounded = (number * 10).rounded() / 10
            let digits = rounded == rounded.rounded()
                ? String(Int(rounded.rounded()))
                : String(format: "%.1f", rounded)
            return digits + unit
        }
    }

    /// The unit a sensor's reading is currently in, or the same fallback `display` would use if it
    /// had no reading at all. For callers (the history scrub readout) that have a number from
    /// elsewhere — a past `HistoryPoint`, not the live state — and need only the unit half of what
    /// `value` would have returned for the *current* reading.
    public static func unit(_ sensor: UpliftedSensor, state: EntityState?) -> String {
        value(sensor, state: state)?.1 ?? defaultUnit(sensor.role)
    }

    /// What to show when the entity declares no unit. A bare degree sign is honest about a
    /// temperature whose scale we weren't told; percent is the only thing humidity is ever in.
    private static func defaultUnit(_ role: UpliftedSensor.Role) -> String {
        role == .temperature ? "°" : "%"
    }
}
