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
    public var isConditioning: Bool {
        guard isOn else { return false }
        guard let hvacAction else { return true }
        return hvacAction != "off" && hvacAction != "idle"
    }
}
