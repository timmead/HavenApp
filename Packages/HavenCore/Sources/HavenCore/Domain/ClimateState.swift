import Foundation
public struct ClimateState: Sendable, Equatable {
    /// The thermostat is not off. **This is a mode, not an activity** — a thermostat set to `heat`
    /// and sitting at its target is `isOn` and doing nothing at all. See `isConditioning`.
    public let isOn: Bool
    public let currentTemp: Double?
    public let targetTemp: Double?
    public let hvacMode: String
    public let modes: [String]
    public let fanMode: String?
    public let fanModes: [String]
    public let unit: String
    /// Home Assistant's `hvac_action`: what the equipment is doing *right now* — `heating`,
    /// `cooling`, `idle`, `off`, `drying`, `fan`, `preheating`, `defrosting`.
    ///
    /// Optional because a large share of climate integrations never report it. Absent means "this
    /// device does not say", which is emphatically not "idle" — see `isConditioning`.
    public let hvacAction: String?
    public init(_ e: EntityState) {
        hvacMode = e.state
        isOn = !e.isUnavailable && e.state != "off"
        currentTemp = e.attributes["current_temperature"]?.asDouble
        targetTemp = e.attributes["temperature"]?.asDouble
        modes = (e.attributes["hvac_modes"]?.asArray ?? []).compactMap { $0.asString }
        fanMode = e.attributes["fan_mode"]?.asString
        fanModes = (e.attributes["fan_modes"]?.asArray ?? []).compactMap { $0.asString }
        unit = e.attributes["temperature_unit"]?.asString ?? "°"
        hvacAction = e.attributes["hvac_action"]?.asString
    }

    /// The equipment is actually running — calling for heat, cooling, drying — as opposed to
    /// merely being switched on and holding its target.
    ///
    /// This is the distinction the tile's fill is about. A thermostat in `heat` mode that has
    /// reached temperature is on but quiet, and lighting its tile for that says "something is
    /// happening here" about a room where nothing is.
    ///
    /// Two deliberate choices:
    ///
    /// - **Defined as "not off and not idle"** rather than as a list of active values. Home
    ///   Assistant has added members to this enum before (`preheating` and `defrosting` are recent),
    ///   and a whitelist would silently read every new one as inactive. The two resting values are
    ///   the stable part.
    /// - **Absent `hvac_action` falls back to `isOn`.** Many integrations never publish the
    ///   attribute; treating "the device didn't say" as "idle" would mean those thermostats could
    ///   never light their tile at all — a fill that vanished for half the world's hardware to fix
    ///   an over-claim for the other half. Falling back keeps the old behaviour exactly where
    ///   there is no better information, and no more claim is made than before.
    ///
    /// `isOn` leads the expression, so an unreachable thermostat is never conditioning whatever
    /// stale `hvac_action` its last-known attributes still carry.
    /// What this thermostat is *for* right now — the thing its colour on the grid means.
    ///
    /// Separate from `isConditioning`, which says whether the equipment is running. The two answer
    /// different questions and the tile shows both: the colour says heating or cooling, the fill
    /// says now or not. An idle heater is therefore a red tile with no wash, which is exactly what
    /// it is — set up to heat, not currently heating.
    public enum Function: Sendable, Equatable {
        case heat, cool, dry, fan
        /// No single answer. `heat_cool` and `auto` are the honest cases: a thermostat that will do
        /// either, currently doing neither, has no colour that is true, so it keeps the domain's own
        /// — as do `off` and anything unreachable.
        case unspecified

        /// Home Assistant's `hvac_action`: what the equipment is doing.
        ///
        /// `idle` and `off` are deliberately absent, and that absence is the mechanism rather than
        /// an omission — they mean "not doing anything", which is a fact about activity and not
        /// about purpose, so they fall through to the mode below. Values HA has added since
        /// (`preheating`, `defrosting`) fall through the same way and land on the mode's colour,
        /// which for a heat-mode thermostat is the right one.
        static func action(_ raw: String) -> Function? {
            switch raw {
            case "heating": return .heat
            case "cooling": return .cool
            case "drying": return .dry
            case "fan": return .fan
            default: return nil
            }
        }

        /// Home Assistant's `hvac_mode`: what it is set to do.
        ///
        /// **Note the vocabulary does not match the action's**, which is the whole reason both
        /// tables are here and under test: HA's mode for drying is `dry` while its action is
        /// `drying`, and its mode for a fan is `fan_only` while its action is `fan`. A single
        /// lookup shared between them would silently colour half of these wrong.
        static func mode(_ raw: String) -> Function? {
            switch raw {
            case "heat": return .heat
            case "cool": return .cool
            case "dry": return .dry
            case "fan_only": return .fan
            default: return nil
            }
        }
    }

    /// The action's answer where there is one, the mode's otherwise.
    ///
    /// In that order because the action is the more specific truth: a `heat_cool` thermostat has no
    /// colour from its mode at all, and yet while it is actively cooling there is exactly one right
    /// answer. The mode is what carries a thermostat that is merely idle, so the tile does not lose
    /// its colour every time the room reaches temperature.
    public var function: Function {
        if let hvacAction, let fromAction = Function.action(hvacAction) { return fromAction }
        return Function.mode(hvacMode) ?? .unspecified
    }

    public var isConditioning: Bool {
        guard isOn else { return false }
        guard let hvacAction else { return true }
        return hvacAction != "off" && hvacAction != "idle"
    }

    /// The mode to ask for when turning a thermostat on from off: the first declared non-`off`
    /// mode, or `heat` if the device declared none.
    ///
    /// A static function of the declared modes rather than an instance property, because the
    /// modal's `ClimateState` is optional: `s?.modeWhenTurningOn ?? "heat"` would put the fallback
    /// literal straight back into the view, which is the duplication this exists to remove.
    /// `ClimateTile`'s power button carries only the `[String]` anyway.
    ///
    /// Order matters and is deliberately left alone: this is the order Home Assistant declared
    /// `hvac_modes` in, not a sorted or otherwise preferred list. `ClimateTile`'s power button and
    /// `ClimateModal`'s header toggle both call this, so the tile and the sheet cannot send
    /// different commands for the same gesture.
    public static func modeWhenTurningOn(from modes: [String]) -> String {
        modes.first { $0 != "off" } ?? "heat"
    }
}
