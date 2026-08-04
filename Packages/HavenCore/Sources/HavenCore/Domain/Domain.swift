import Foundation

public enum Domain: String, Sendable, Equatable, CaseIterable {
    case light, switchOutlet, cover, lock, climate, mediaPlayer, camera, scene, script, button, sensor, binarySensor, unknown

    public static func of(_ entityId: String) -> Domain {
        switch String(entityId.prefix(while: { $0 != "." })) {
        case "light": return .light
        case "switch", "input_boolean": return .switchOutlet
        case "cover": return .cover
        case "lock": return .lock
        case "climate": return .climate
        case "media_player": return .mediaPlayer
        case "camera": return .camera
        case "scene": return .scene
        case "script": return .script
        case "button", "input_button": return .button
        case "binary_sensor": return .binarySensor
        case "sensor": return .sensor
        default: return .unknown
        }
    }
    /// Whether this domain is something the user *operates*. A camera is deliberately not one: the
    /// renderer offers viewing and a mute control over the live feed, and nothing that changes the
    /// state of the home. Treating it as an actuator would put it in reach of the bulk actions and
    /// roll-ups, which act on things that turn on and off.
    public var isActuator: Bool {
        switch self {
        case .light, .switchOutlet, .cover, .lock, .climate, .mediaPlayer, .scene, .script, .button: return true
        case .camera, .sensor, .binarySensor, .unknown: return false
        }
    }
    /// The HA *service* domain — always the entity-id prefix, so `input_boolean.x`
    /// calls `input_boolean.turn_on` rather than `switch.turn_on`.
    public static func serviceDomain(of entityId: String) -> String {
        String(entityId.prefix(while: { $0 != "." }))
    }
}

public extension EntityState {
    var deviceClass: String? { attributes["device_class"]?.asString }
}
