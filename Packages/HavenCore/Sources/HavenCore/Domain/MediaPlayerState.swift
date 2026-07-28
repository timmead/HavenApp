import Foundation

/// Home Assistant's `media_player` `supported_features` bitfield.
///
/// **Every control in the media player renderer is gated on one of these bits, and an unsupported
/// control is omitted rather than shown disabled.** That makes a wrong bit value fail in a
/// specific, survivable direction: a control that should be there disappears. It can never make
/// the app call a service the device does not implement, because the same bit that draws a button
/// is the one that permits its command — there is no path that sends `media_next_track` without
/// `nextTrack` being set.
///
/// The numeric values are Home Assistant's `MediaPlayerEntityFeature`, written once here as
/// literals so a correction is a one-line change. `64` is deliberately absent: it was
/// `PLAY_MEDIA`'s predecessor and has been unused for years, and inventing a name for a bit no
/// integration sets would be worse than the gap.
public struct MediaPlayerFeatures: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let pause           = MediaPlayerFeatures(rawValue: 1)
    public static let seek            = MediaPlayerFeatures(rawValue: 2)
    public static let volumeSet       = MediaPlayerFeatures(rawValue: 4)
    public static let volumeMute      = MediaPlayerFeatures(rawValue: 8)
    public static let previousTrack   = MediaPlayerFeatures(rawValue: 16)
    public static let nextTrack       = MediaPlayerFeatures(rawValue: 32)
    public static let turnOn          = MediaPlayerFeatures(rawValue: 128)
    public static let turnOff         = MediaPlayerFeatures(rawValue: 256)
    public static let playMedia       = MediaPlayerFeatures(rawValue: 512)
    public static let volumeStep      = MediaPlayerFeatures(rawValue: 1024)
    public static let selectSource    = MediaPlayerFeatures(rawValue: 2048)
    public static let stop            = MediaPlayerFeatures(rawValue: 4096)
    public static let clearPlaylist   = MediaPlayerFeatures(rawValue: 8192)
    public static let play            = MediaPlayerFeatures(rawValue: 16384)
    public static let shuffleSet      = MediaPlayerFeatures(rawValue: 32768)
    public static let selectSoundMode = MediaPlayerFeatures(rawValue: 65536)
    public static let browseMedia     = MediaPlayerFeatures(rawValue: 131072)
    public static let repeatSet       = MediaPlayerFeatures(rawValue: 262144)
    public static let grouping        = MediaPlayerFeatures(rawValue: 524288)

    /// A device that can be asked to start *or* stop — either half is enough to draw the one
    /// play/pause button, since which service it sends is decided by the current state and both
    /// halves are separately checked before sending (see `MediaPlayerState.canPlay`/`canPause`).
    public var supportsPlayPause: Bool { !isDisjoint(with: [.play, .pause]) }

    /// Whether the header may show a power toggle at all. Both halves are required: a toggle that
    /// can be switched one way and not back is worse than no toggle, which is what the design asks
    /// for when power is unsupported.
    public var supportsPower: Bool { contains(.turnOn) && contains(.turnOff) }

    /// Decodes the raw attribute. Absent, non-numeric or negative all mean "nothing supported":
    /// the renderer then draws no transport at all, which is honest about knowing nothing, rather
    /// than offering controls on a hunch.
    public init(attribute: JSONValue?) {
        self.init(rawValue: max(0, attribute?.asInt ?? 0))
    }
}

/// A `media_player` entity's state, typed.
///
/// Playback, position and most attributes are read straight off what Home Assistant publishes;
/// nothing here interpolates or ticks — that is `MediaProgress`, deliberately separate so the value
/// that changes every second isn't baked into a struct compared for equality on every state push.
/// `features` is the one exception to "straight off the attributes": see its init line.
public struct MediaPlayerState: Sendable, Equatable {
    /// Home Assistant's own `media_player` state strings, one case each, so an unrecognised state
    /// is `.unknown` rather than silently coerced into a plausible neighbour. `on` is real and
    /// distinct from `idle`: several integrations report a powered receiver with no source as
    /// plain `on`, and it is also what an optimistic power-on writes (see `MediaPlayerOptimistic`).
    public enum Playback: String, Sendable, Equatable, CaseIterable {
        case playing, paused, buffering, idle, standby, on, off, unavailable, unknown

        /// Buffering counts as playing: the track is running, the position ticks, and the button
        /// the user needs is Pause.
        public var isPlaying: Bool { self == .playing || self == .buffering }

        /// Powered and reachable — i.e. anything but off, unavailable, or a state we can't name.
        public var isActive: Bool {
            switch self {
            case .playing, .paused, .buffering, .idle, .standby, .on: return true
            case .off, .unavailable, .unknown: return false
            }
        }

        /// The word shown in the modal subtitle and spoken by VoiceOver — state carried as text,
        /// not only as colour.
        public var label: String {
            switch self {
            case .playing: return "Playing"
            case .paused: return "Paused"
            case .buffering: return "Buffering"
            case .idle: return "Idle"
            case .standby: return "Standby"
            case .on: return "On"
            case .off: return "Off"
            case .unavailable: return "Unavailable"
            case .unknown: return "Unknown"
            }
        }
    }

    public let playback: Playback
    public let title: String?
    public let artist: String?
    public let album: String?
    /// `app_name` — "Spotify", "YouTube". The last resort for a secondary line when a stream
    /// reports no artist or album, which is the norm for radio and casting.
    public let appName: String?
    /// `entity_picture`: relative to the instance for local artwork, absolute and foreign for
    /// Spotify/Sonos-served art. Resolution and the same-origin token decision are `HAImageURL`'s.
    public let artworkPath: String?
    /// `volume_level` (0…1) rendered as whole percent, or `nil` when the device reports none.
    public let volumePercent: Int?
    public let isMuted: Bool
    public let source: String?
    public let sourceList: [String]
    /// `media_position`, in seconds, as of `positionUpdatedAt` — **not** as of now. See
    /// `MediaProgress`.
    public let position: Double?
    public let positionUpdatedAt: Date?
    public let duration: Double?
    /// `[]` whenever the entity is unavailable — **not** whatever `supported_features` says.
    ///
    /// Home Assistant keeps `supported_features` on an unavailable entity, because it is a
    /// *capability* of the device rather than a live reading, unlike `media_title`/`volume_level`,
    /// which it drops. Read verbatim, that capability bit still draws a tinted, tappable transport
    /// on a device Home Assistant cannot currently reach — the same false claim this project's
    /// unavailable-state work exists to remove elsewhere. Zeroing it here, at the source, removes
    /// every control gated on a feature bit (play/pause on all three tile sizes and the modal's
    /// transport, volume, source and power toggle) in one place, rather than threading an
    /// `unavailable` flag through each renderer that reads `features`.
    public let features: MediaPlayerFeatures

    public init(_ e: EntityState) {
        playback = Playback(rawValue: e.state) ?? .unknown
        title = Self.text(e.attributes["media_title"])
        artist = Self.text(e.attributes["media_artist"])
        album = Self.text(e.attributes["media_album_name"])
        appName = Self.text(e.attributes["app_name"])
        artworkPath = Self.text(e.attributes["entity_picture"])
        if let level = e.attributes["volume_level"]?.asDouble {
            volumePercent = max(0, min(100, Int((level * 100).rounded())))
        } else {
            volumePercent = nil
        }
        isMuted = e.attributes["is_volume_muted"]?.asBool ?? false
        source = Self.text(e.attributes["source"])
        sourceList = (e.attributes["source_list"]?.asArray ?? []).compactMap { $0.asString }
        position = e.attributes["media_position"]?.asDouble
        positionUpdatedAt = MediaProgress.parseUpdatedAt(e.attributes["media_position_updated_at"])
        duration = e.attributes["media_duration"]?.asDouble
        // See `features`' own doc: an unavailable entity still carries `supported_features` (it is
        // a capability, not a reading), so this must not read it verbatim or every transport
        // control survives a device Home Assistant cannot reach.
        features = e.isUnavailable ? [] : MediaPlayerFeatures(attribute: e.attributes["supported_features"])
    }

    public var isPlaying: Bool { playback.isPlaying }
    public var isActive: Bool { playback.isActive }

    /// Whether there is anything to *show* — as opposed to anything to control. A powered speaker
    /// sitting idle has no title, and the tiles that would otherwise render an empty text window
    /// fall back to the entity's name instead.
    public var hasMedia: Bool { title != nil }

    /// Artist, else album, else the app doing the playing. One line, whichever of the three the
    /// integration actually filled in.
    public var secondaryLine: String? { artist ?? album ?? appName }

    /// Play is offered when the device supports it and isn't already playing; pause the mirror
    /// image. Both are checked before the command is sent, so a device that reports only one of
    /// the two bits gets exactly the half it declared.
    public var canPlay: Bool { features.contains(.play) && !isPlaying }
    public var canPause: Bool { features.contains(.pause) && isPlaying }

    /// The single play/pause button is drawn when either half is available — it renders as Pause
    /// while playing and Play otherwise, and each of those is gated by `canPause`/`canPlay`.
    public var showsPlayPause: Bool { canPlay || canPause }

    /// Whether setting a volume level should *also* clear mute.
    ///
    /// It should, and the reason is that the alternative is a control that visibly does nothing:
    /// dragging a volume slider on a muted speaker changes `volume_level` and produces no sound and
    /// no audible difference whatsoever, which reads as a broken slider rather than as a mute the
    /// user forgot about. Reaching for the volume is an unambiguous request to hear something.
    ///
    /// Gated on the device declaring `volumeMute`, because on a player without it there is no mute
    /// to clear and sending `volume_mute` would be a call the device never said it accepts — the
    /// same omit-don't-guess rule every control here follows.
    ///
    /// **This does not weaken the mute button.** Mute remains a control of its own that means
    /// exactly what it says; this only decides what a *volume change* implies, and only in the one
    /// direction — nothing here ever mutes.
    public var volumeChangeShouldUnmute: Bool {
        isMuted && features.contains(.volumeMute)
    }

    private static func text(_ v: JSONValue?) -> String? {
        guard let s = v?.asString else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
