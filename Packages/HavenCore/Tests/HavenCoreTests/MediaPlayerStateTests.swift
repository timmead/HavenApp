import Testing
import Foundation
@testable import HavenCore

private func mp(_ st: String, _ a: [String: JSONValue] = [:]) -> EntityState {
    EntityState(entityId: "media_player.kitchen", state: st, attributes: a, lastUpdated: .init())
}

@Test func mediaPlayerDecodesNowPlaying() {
    let s = MediaPlayerState(mp("playing", [
        "media_title": .string("So What"),
        "media_artist": .string("Miles Davis"),
        "media_album_name": .string("Kind of Blue"),
        "app_name": .string("Spotify"),
        "entity_picture": .string("/api/media_player_proxy/media_player.kitchen?token=abc"),
        "volume_level": .double(0.37),
        "is_volume_muted": .bool(false),
        "source": .string("Spotify"),
        "source_list": .array([.string("Spotify"), .string("TV")]),
        "media_duration": .double(545),
    ]))
    #expect(s.playback == .playing)
    #expect(s.isPlaying)
    #expect(s.isActive)
    #expect(s.hasMedia)
    #expect(s.title == "So What")
    #expect(s.secondaryLine == "Miles Davis")
    #expect(s.volumePercent == 37)
    #expect(!s.isMuted)
    #expect(s.sourceList == ["Spotify", "TV"])
    #expect(s.duration == 545)
    #expect(s.artworkPath == "/api/media_player_proxy/media_player.kitchen?token=abc")
}

@Test func mediaPlayerPlaybackCoversHomeAssistantsStates() {
    // Every state Home Assistant's media_player can report has its own case: an unrecognised one
    // must land on `.unknown` rather than be coerced into a plausible neighbour (an unreachable
    // speaker rendering as "idle" would offer transport controls that go nowhere).
    #expect(MediaPlayerState(mp("paused")).playback == .paused)
    #expect(MediaPlayerState(mp("buffering")).playback == .buffering)
    #expect(MediaPlayerState(mp("standby")).playback == .standby)
    #expect(MediaPlayerState(mp("on")).playback == .on)
    #expect(MediaPlayerState(mp("off")).playback == .off)
    #expect(MediaPlayerState(mp("unavailable")).playback == .unavailable)
    #expect(MediaPlayerState(mp("wat")).playback == .unknown)

    // Buffering is playing: the track is running and the button the user wants is Pause.
    #expect(MediaPlayerState(mp("buffering")).isPlaying)
    #expect(!MediaPlayerState(mp("paused")).isPlaying)
    // Powered-but-idle is still active; off/unavailable/unknown are not.
    #expect(MediaPlayerState(mp("idle")).isActive)
    #expect(!MediaPlayerState(mp("off")).isActive)
    #expect(!MediaPlayerState(mp("unavailable")).isActive)
    #expect(!MediaPlayerState(mp("wat")).isActive)
}

@Test func mediaPlayerSecondaryLineFallsBackThroughAlbumToApp() {
    #expect(MediaPlayerState(mp("playing", ["media_album_name": .string("Kind of Blue")])).secondaryLine == "Kind of Blue")
    #expect(MediaPlayerState(mp("playing", ["app_name": .string("TuneIn")])).secondaryLine == "TuneIn")
    #expect(MediaPlayerState(mp("playing")).secondaryLine == nil)
    // A blank string is not a value — it would render as an empty second line that pushes the
    // layout around for no information at all.
    #expect(MediaPlayerState(mp("playing", ["media_title": .string("   ")])).title == nil)
    #expect(!MediaPlayerState(mp("playing", ["media_title": .string("")])).hasMedia)
}

@Test func mediaPlayerVolumeRoundTripsAsWholePercent() {
    #expect(MediaPlayerState(mp("playing", ["volume_level": .double(0.0)])).volumePercent == 0)
    #expect(MediaPlayerState(mp("playing", ["volume_level": .double(1.0)])).volumePercent == 100)
    #expect(MediaPlayerState(mp("playing", ["volume_level": .double(0.375)])).volumePercent == 38)
    // A device reporting no level must read as "unknown", not as silence — a slider resting at 0
    // for a speaker that is audibly playing is a lie the user cannot correct.
    #expect(MediaPlayerState(mp("playing")).volumePercent == nil)
    // Out-of-range input clamps rather than producing a slider value outside its own bounds.
    #expect(MediaPlayerState(mp("playing", ["volume_level": .double(1.4)])).volumePercent == 100)
    #expect(MediaPlayerState(mp("playing", ["volume_level": .double(-0.2)])).volumePercent == 0)
}

@Test func supportedFeaturesDecodeIndividually() {
    let f = MediaPlayerFeatures(attribute: .int(1 | 4 | 8 | 16 | 32 | 2048))
    #expect(f.contains(.pause))
    #expect(f.contains(.volumeSet))
    #expect(f.contains(.volumeMute))
    #expect(f.contains(.previousTrack))
    #expect(f.contains(.nextTrack))
    #expect(f.contains(.selectSource))
    #expect(!f.contains(.play))
    #expect(!f.contains(.turnOn))
    #expect(!f.supportsPower)
}

@Test func supportedFeaturesDecodesARealisticCompositeValue() {
    // A Sonos-shaped bitfield: pause, seek, volume set/mute, prev/next, play media, volume step,
    // select source, stop, clear playlist, play, shuffle, browse, repeat, grouping. Deliberately a
    // large composite rather than one bit at a time — the failure this guards against is a decoder
    // that works for small values and truncates a real one.
    let raw = 1 | 2 | 4 | 8 | 16 | 32 | 512 | 1024 | 2048 | 4096 | 8192 | 16384 | 32768 | 131072 | 262144 | 524288
    let f = MediaPlayerFeatures(attribute: .int(raw))
    #expect(f.supportsPlayPause)
    #expect(f.contains(.nextTrack) && f.contains(.previousTrack))
    #expect(f.contains(.volumeSet) && f.contains(.volumeMute))
    #expect(f.contains(.selectSource))
    // Sonos speakers have no power: this is exactly the case where the header shows the hand-off
    // button instead of a toggle.
    #expect(!f.supportsPower)
}

@Test func supportedFeaturesArrivingAsADoubleDoesNotTruncate() {
    // JSON numbers can decode as `.double`; a large `supported_features` must survive it intact,
    // or the high bits (select source at 2048, grouping at 524288) silently vanish and the
    // controls they gate disappear with no error anywhere.
    let raw = 1 | 4 | 2048 | 524288
    #expect(MediaPlayerFeatures(attribute: .double(Double(raw))).rawValue == raw)
}

@Test func supportedFeaturesAbsentOrNonsenseMeansNothingSupported() {
    #expect(MediaPlayerFeatures(attribute: nil).rawValue == 0)
    #expect(MediaPlayerFeatures(attribute: .string("lots")).rawValue == 0)
    // Negative is nonsense; it must not become an OptionSet that answers "yes" to everything.
    let negative = MediaPlayerFeatures(attribute: .int(-1))
    #expect(negative.rawValue == 0)
    #expect(!negative.contains(.play) && !negative.supportsPower && !negative.supportsPlayPause)
}

@Test func powerToggleNeedsBothHalves() {
    // A toggle that switches one way and not back is worse than no toggle — which is what the
    // design asks for when power is unsupported.
    #expect(!MediaPlayerFeatures(rawValue: 128).supportsPower)
    #expect(!MediaPlayerFeatures(rawValue: 256).supportsPower)
    #expect(MediaPlayerFeatures(rawValue: 128 | 256).supportsPower)
}

@Test func playPauseIsGatedPerDirection() {
    let attrs: [String: JSONValue] = ["supported_features": .int(16384)]   // PLAY only
    let paused = MediaPlayerState(mp("paused", attrs))
    #expect(paused.canPlay)
    #expect(!paused.canPause)
    #expect(paused.showsPlayPause)

    // The same device while playing offers nothing: it never declared PAUSE, so no button is drawn
    // rather than one that would send a service it doesn't implement.
    let playing = MediaPlayerState(mp("playing", attrs))
    #expect(!playing.canPause)
    #expect(!playing.showsPlayPause)

    let both = MediaPlayerState(mp("playing", ["supported_features": .int(1 | 16384)]))
    #expect(both.canPause && !both.canPlay && both.showsPlayPause)
}

@Test func mediaPlayerAccessibilityLabelCarriesStateInText() {
    let playing = MediaPlayerState(mp("playing", [
        "media_title": .string("So What"), "media_artist": .string("Miles Davis"),
        "volume_level": .double(0.4),
    ]))
    #expect(AccessibilitySummary.mediaPlayer("Kitchen", playing) == "Kitchen, playing, So What by Miles Davis, volume 40%")

    let idle = MediaPlayerState(mp("idle", ["volume_level": .double(0.4)]))
    #expect(AccessibilitySummary.mediaPlayer("Kitchen", idle) == "Kitchen, idle, nothing playing, volume 40%")

    // Muted is spoken instead of the level: "volume 40%" on a muted speaker is actively misleading.
    let muted = MediaPlayerState(mp("playing", [
        "media_title": .string("So What"), "is_volume_muted": .bool(true), "volume_level": .double(0.4),
    ]))
    #expect(AccessibilitySummary.mediaPlayer("Kitchen", muted) == "Kitchen, playing, So What, muted")

    #expect(AccessibilitySummary.mediaPlayer("Kitchen", MediaPlayerState(mp("off"))) == "Kitchen, off")
    #expect(AccessibilitySummary.mediaPlayer("Kitchen", MediaPlayerState(mp("unavailable"))) == "Kitchen, unavailable")
}
