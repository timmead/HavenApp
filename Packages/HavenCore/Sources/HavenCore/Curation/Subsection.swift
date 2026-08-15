import Foundation

/// Which subsection a device belongs to, and how it renders there.
///
/// Rooms group their devices into opinionated, per-domain containers — Climate, Lights, Shades,
/// Media, Cameras, "Scenes & more", Sensors — shown on both the floor view and the room detail
/// view. `SubsectionKind` is that vocabulary and the bucketing rule that assigns an entity to one;
/// `SubsectionMode` is how a subsection's tiles are laid out.
public enum SubsectionKind: String, CaseIterable, Sendable {
    case climate, lights, shades, media, cameras, other, sensors

    /// The heading shown above this subsection's tiles.
    public var displayName: String {
        switch self {
        case .climate: return "Climate"
        case .lights: return "Lights"
        case .shades: return "Shades"
        case .media: return "Media"
        case .cameras: return "Cameras"
        case .other: return "Scenes & more"
        case .sensors: return "Sensors"
        }
    }

    /// Which subsection an entity's primary lands in.
    ///
    /// Moved from `RoomDetailView.grouped`, where nothing could test it. Switches on
    /// `Domain.of(_:)` exhaustively — no `default` — so a new `Domain` case fails to compile here
    /// rather than silently bucketing, and every entity lands in exactly one kind: none dropped,
    /// none duplicated.
    public static func of(_ primaryEntityId: String) -> SubsectionKind {
        // A composite is bucketed by what its primary is: a shade group sits with the shades.
        switch Domain.of(primaryEntityId) {
        case .climate: return .climate
        case .light: return .lights
        case .cover: return .shades
        case .mediaPlayer: return .media
        // Its own bucket, not `.other`: `.other` renders in the 4-column grid, and a camera
        // has no 1-column size — see `cameraGroup`.
        case .camera: return .cameras
        case .scene, .script, .button, .lock, .switchOutlet, .unknown: return .other
        case .sensor, .binarySensor: return .sensors
        }
    }

    /// The size this subsection's tiles render at before the household chooses otherwise.
    ///
    /// Delegates to `TileSpan.default(for:on:)` for kinds with one governing domain, so an
    /// unconfigured document renders exactly today's proportions — the spec's compatibility
    /// promise. `.other` and `.sensors` span several domains with no single default among them, so
    /// both fall back to the smallest rendering, 1×1.
    public func defaultSpan(on surface: HavenSurface) -> TileSpan {
        switch self {
        case .climate: return TileSpan.default(for: .climate, on: surface)
        case .lights: return TileSpan.default(for: .light, on: surface)
        case .shades: return TileSpan.default(for: .cover, on: surface)
        case .media: return TileSpan.default(for: .mediaPlayer, on: surface)
        case .cameras: return TileSpan.default(for: .camera, on: surface)
        case .other, .sensors: return TileSpan(columns: 1, rows: 1)
        }
    }

    /// The size picker's option list for this subsection.
    ///
    /// Every offered span must be drawable by the kind's *most capable* member
    /// (`TileSpan.available`), because subsection sizing is uniform: a kind whose members disagree
    /// offers only what the least capable can occupy without a bespoke rendering — the existing
    /// smallest-rendering fallback covers the rest. `.other` mixes several single-size domains, so
    /// it offers only the one size they share.
    public var availableSpans: [TileSpan] {
        switch self {
        case .climate: return TileSpan.available(for: .climate)
        case .lights: return TileSpan.available(for: .light)
        case .shades: return TileSpan.available(for: .cover)
        case .media: return TileSpan.available(for: .mediaPlayer)
        case .cameras: return TileSpan.available(for: .camera)
        case .other: return [TileSpan(columns: 1, rows: 1)]
        case .sensors: return TileSpan.available(for: .sensor)
        }
    }
}

/// How a subsection's tiles are arranged: a horizontal scroll row, or a wrapping grid.
public enum SubsectionMode: String, Sendable, Codable {
    case scroll, wrap
}
