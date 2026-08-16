import Foundation

/// The kinds of thing a room holds, as a user would group them.
///
/// Exists for the add-tile picker's filter, which needs a short, stable list of tickboxes rather
/// than the twelve `Domain` cases — nobody thinks of "script" and "button" as separate kinds of
/// thing to put on a wall.
///
/// The buckets and their order match `SubsectionKind`, which is what a room is actually rendered
/// as. Two types rather than one because they answer different questions — a picker's filter is not
/// a room's layout — but deliberately the same list, so they cannot drift into disagreeing about
/// what a "sensor" is.
public enum TileCategory: String, Sendable, Codable, CaseIterable, Hashable {
    case climate, lights, shades, media, cameras, scenesAndMore, sensors

    public init(domain: Domain) {
        switch domain {
        case .climate: self = .climate
        case .light: self = .lights
        case .cover: self = .shades
        case .mediaPlayer: self = .media
        case .camera: self = .cameras
        case .scene, .script, .button, .lock, .switchOutlet, .unknown: self = .scenesAndMore
        case .sensor, .binarySensor: self = .sensors
        }
    }

    /// What the filter sheet calls it.
    public var label: String {
        switch self {
        case .climate: return "Climate"
        case .lights: return "Lights"
        case .shades: return "Shades"
        case .media: return "Media"
        case .cameras: return "Cameras"
        case .scenesAndMore: return "Scenes & more"
        case .sensors: return "Sensors"
        }
    }

    public var symbol: String {
        switch self {
        case .climate: return "thermometer.medium"
        case .lights: return "lightbulb.fill"
        case .shades: return "blinds.vertical.closed"
        case .media: return "speaker.wave.2.fill"
        case .cameras: return "video.fill"
        case .scenesAndMore: return "sparkles"
        case .sensors: return "sensor.fill"
        }
    }
}
