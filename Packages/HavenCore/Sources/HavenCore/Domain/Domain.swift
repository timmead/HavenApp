import Foundation

public enum Domain: String, Sendable, Equatable {
    case light, switchOutlet, cover, lock, climate, scene, script, button, sensor, binarySensor, unknown

    public static func of(_ entityId: String) -> Domain {
        switch String(entityId.prefix(while: { $0 != "." })) {
        case "light": return .light
        case "switch", "input_boolean": return .switchOutlet
        case "cover": return .cover
        case "lock": return .lock
        case "climate": return .climate
        case "scene": return .scene
        case "script": return .script
        case "button", "input_button": return .button
        case "binary_sensor": return .binarySensor
        case "sensor": return .sensor
        default: return .unknown
        }
    }
    public var isActuator: Bool {
        switch self {
        case .light, .switchOutlet, .cover, .lock, .climate, .scene, .script, .button: return true
        case .sensor, .binarySensor, .unknown: return false
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
