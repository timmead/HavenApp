import Foundation

/// Home Assistant's `camera` `supported_features` bitfield (`CameraEntityFeature`).
///
/// Only two bits exist, and only one of them is load-bearing here: `stream` decides whether the
/// modal can ask for an HLS URL at all (see `CameraStream.source`). `onOff` is decoded for
/// completeness and deliberately unused — Haven's camera renderer never turns a camera off, because
/// a control that silently stops a security camera recording is not something to put one tap away
/// from a thumbnail.
public struct CameraFeatures: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let onOff  = CameraFeatures(rawValue: 1)
    public static let stream = CameraFeatures(rawValue: 2)

    /// Absent, non-numeric or negative all mean "nothing declared", which routes the modal to the
    /// snapshot fallback rather than to a stream request the camera may not answer.
    public init(attribute: JSONValue?) {
        self.init(rawValue: max(0, attribute?.asInt ?? 0))
    }
}

/// A `camera` entity's state, typed.
///
/// Nothing here fetches, refreshes or times anything: the snapshot *path* is a pure function of the
/// entity id, the staleness *stamp* is `CameraSnapshotAge`, and the live-view URL is
/// `CameraStream`. Each is separately testable, which matters more here than elsewhere because the
/// one thing this renderer must never do is show a confident picture of the wrong moment.
public struct CameraState: Sendable, Equatable {
    /// Home Assistant's own `camera` state strings. `idle` is the ordinary resting state of a
    /// perfectly healthy camera — it means "not currently recording or streaming", **not** "off" —
    /// which is why it is `isAvailable` below and reads as "Idle" rather than as a problem.
    public enum Status: String, Sendable, Equatable, CaseIterable {
        case recording, streaming, idle, unavailable, unknown

        /// Reachable and able to produce a picture.
        public var isAvailable: Bool {
            switch self {
            case .recording, .streaming, .idle: return true
            case .unavailable, .unknown: return false
            }
        }

        /// The word shown in the caption strip and spoken by VoiceOver — state carried as text,
        /// never only as a colour or a dot.
        public var label: String {
            switch self {
            case .recording: return "Recording"
            case .streaming: return "Streaming"
            case .idle: return "Idle"
            case .unavailable: return "Unavailable"
            case .unknown: return "Unknown"
            }
        }
    }

    public let status: Status
    /// `entity_picture` — HA's own signed snapshot reference
    /// (`/api/camera_proxy/camera.x?token=…`). Kept for completeness; the tiles deliberately use
    /// `snapshotPath(for:)` instead, see there.
    public let entityPicture: String?
    /// `access_token` — the short-lived signed token HA rotates for this camera's proxy URLs.
    ///
    /// **Never logged and never used as a cache key** (`HAImageURL.cacheKey` has no parameter it
    /// could be passed through). It is carried only so an unauthenticated consumer — an
    /// `AVPlayer`, which cannot be given an `Authorization` header — could be handed a URL that
    /// works. Nothing today does, which is why it is not in `CameraStream`'s output.
    public let accessToken: String?
    public let features: CameraFeatures
    /// `frontend_stream_type` — `"hls"` or `"web_rtc"`. Read so a WebRTC-only camera is
    /// *recognisable* rather than silently failing an HLS request; see `CameraStream.source`.
    public let frontendStreamType: String?
    public let brand: String?
    public let model: String?
    public let motionDetection: Bool

    public init(_ e: EntityState) {
        status = Status(rawValue: e.state) ?? .unknown
        entityPicture = Self.text(e.attributes["entity_picture"])
        accessToken = Self.text(e.attributes["access_token"])
        features = CameraFeatures(attribute: e.attributes["supported_features"])
        frontendStreamType = Self.text(e.attributes["frontend_stream_type"])
        brand = Self.text(e.attributes["brand"])
        model = Self.text(e.attributes["model"])
        motionDetection = e.attributes["motion_detection"]?.asBool ?? false
    }

    public var isAvailable: Bool { status.isAvailable }
    public var supportsStream: Bool { features.contains(.stream) }

    /// The unsigned snapshot path for a camera, `/api/camera_proxy/<entity_id>`.
    ///
    /// Deliberately preferred over `entity_picture` for the tiles even though HA publishes the
    /// latter. Two reasons, both about the refresh cycle:
    ///
    /// - `entity_picture` carries a rotating `?token=…`. That query is part of
    ///   `HAImageURL.cacheKey`, so every rotation would mint a *new* cache entry while the old one
    ///   stayed resident — a camera refreshing every ten seconds would fill and evict the shared
    ///   image cache on its own, pushing out every other tile's artwork.
    /// - The token is a credential with a lifetime we don't control. A stable path plus the bearer
    ///   token the loader already attaches same-origin (`ResolvedImageURL.authorize`) is the same
    ///   picture with one fewer secret in flight.
    public static func snapshotPath(for entityId: String) -> String {
        "/api/camera_proxy/\(entityId)"
    }

    private static func text(_ v: JSONValue?) -> String? {
        guard let s = v?.asString else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
