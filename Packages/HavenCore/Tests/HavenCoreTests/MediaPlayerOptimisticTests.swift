import Testing
import Foundation
@testable import HavenCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func playing(positionAt: Date = t0, position: Double = 30) -> EntityState {
    EntityState(entityId: "media_player.kitchen", state: "playing", attributes: [
        "media_title": .string("So What"),
        "media_artist": .string("Miles Davis"),
        "entity_picture": .string("/api/media_player_proxy/media_player.kitchen"),
        "media_position": .double(position),
        "media_position_updated_at": .string(MediaProgress.formatUpdatedAt(positionAt)),
        "media_duration": .double(545),
        "volume_level": .double(0.4),
        "source": .string("Spotify"),
        "supported_features": .int(1 | 16384 | 4 | 8 | 128 | 256),
    ], lastUpdated: t0)
}

/// What is on screen at `now`, read the same way the modal reads it.
private func onScreenElapsed(_ e: EntityState, at now: Date) -> Double? {
    let s = MediaPlayerState(e)
    return MediaProgress.elapsed(position: s.position, updatedAt: s.positionUpdatedAt,
                                 isPlaying: s.isPlaying, duration: s.duration, now: now)
}

@Test func pausingFreezesTheBarWhereItWasOnScreen() {
    // The bug this exists to prevent: flipping only `state` leaves `media_position` reading 30s
    // while the bar was showing 75s, so it visibly jumps backwards at the moment of the pause.
    let atPause = t0.addingTimeInterval(45)
    let before = playing()
    #expect(onScreenElapsed(before, at: atPause) == 75)

    let after = MediaPlayerOptimistic.playPause(before, now: atPause)
    #expect(MediaPlayerState(after).playback == .paused)
    #expect(onScreenElapsed(after, at: atPause) == 75)
    // And it stays there: a paused bar must not creep while Home Assistant's echo is in flight.
    #expect(onScreenElapsed(after, at: atPause.addingTimeInterval(300)) == 75)
}

@Test func resumingContinuesFromWhereItWasPausedRatherThanJumpingForward() {
    // Restamping matters just as much in this direction. A resume that leaves a ten-minute-old
    // `media_position_updated_at` in place would interpolate those ten minutes the instant the
    // state flips to playing, and the bar would leap forward — or straight to the end.
    let pausedAt = t0.addingTimeInterval(45)
    let paused = MediaPlayerOptimistic.playPause(playing(), now: pausedAt)
    let resumedAt = pausedAt.addingTimeInterval(600)

    let resumed = MediaPlayerOptimistic.playPause(paused, now: resumedAt)
    #expect(MediaPlayerState(resumed).playback == .playing)
    #expect(onScreenElapsed(resumed, at: resumedAt) == 75)
    // Ticking again from there, not from 675.
    #expect(onScreenElapsed(resumed, at: resumedAt.addingTimeInterval(10)) == 85)
}

@Test func playPauseOnAPlayerWithNoPositionLeavesThePositionAlone() {
    // A live stream reports no position. Inventing one here would draw a progress bar for
    // something that has no progress.
    let e = EntityState(entityId: "media_player.radio", state: "playing",
                        attributes: ["media_title": .string("BBC 6 Music")], lastUpdated: t0)
    let after = MediaPlayerOptimistic.playPause(e, now: t0.addingTimeInterval(5))
    #expect(MediaPlayerState(after).playback == .paused)
    #expect(after.attributes["media_position"] == nil)
    #expect(after.attributes["media_position_updated_at"] == nil)
}

@Test func playingFromIdleStartsThePositionTicking() {
    let e = EntityState(entityId: "media_player.kitchen", state: "idle",
                        attributes: ["media_position": .double(0), "media_duration": .double(300),
                                     "media_position_updated_at": .string(MediaProgress.formatUpdatedAt(t0))],
                        lastUpdated: t0)
    let startedAt = t0.addingTimeInterval(120)
    let after = MediaPlayerOptimistic.playPause(e, now: startedAt)
    #expect(MediaPlayerState(after).playback == .playing)
    // Zero at the moment of the tap — not 120, which is what an unrestamped timestamp would give.
    #expect(onScreenElapsed(after, at: startedAt) == 0)
    #expect(onScreenElapsed(after, at: startedAt.addingTimeInterval(30)) == 30)
}

@Test func optimisticVolumeRoundTripsThroughTheSameConversionTheSliderReads() {
    for percent in [0, 1, 37, 50, 99, 100] {
        let after = MediaPlayerOptimistic.volume(playing(), percent: percent)
        #expect(MediaPlayerState(after).volumePercent == percent)
    }
    // Out-of-range input clamps rather than writing a `volume_level` outside 0…1.
    #expect(MediaPlayerState(MediaPlayerOptimistic.volume(playing(), percent: 140)).volumePercent == 100)
    #expect(MediaPlayerState(MediaPlayerOptimistic.volume(playing(), percent: -20)).volumePercent == 0)
}

/// A volume change on a muted player sends `volume_mute(false)` *and* `volume_set`, so both halves
/// must land optimistically together. Writing only the level would leave the slider filling in while
/// the mute glyph on the same row still read "muted" until Home Assistant's echo arrived — two
/// controls in one row disagreeing, which is the bug class this whole type exists for.
@Test func optimisticVolumeCanClearMuteInTheSameWrite() {
    let muted = MediaPlayerOptimistic.mute(playing(), muted: true)
    let after = MediaPlayerOptimistic.volume(muted, percent: 55, unmuting: true)
    #expect(MediaPlayerState(after).volumePercent == 55)
    #expect(!MediaPlayerState(after).isMuted)
}

/// The default is unchanged, and deliberately so: an ordinary level change on an unmuted player
/// must not touch `is_volume_muted` at all.
@Test func optimisticVolumeLeavesMuteAloneByDefault() {
    let muted = MediaPlayerOptimistic.mute(playing(), muted: true)
    #expect(MediaPlayerState(MediaPlayerOptimistic.volume(muted, percent: 55)).isMuted)
    #expect(!MediaPlayerState(MediaPlayerOptimistic.volume(playing(), percent: 55)).isMuted)
}

@Test func optimisticMuteLeavesTheLevelAlone() {
    // Home Assistant's mute is independent of level; zeroing the level here would make un-muting
    // restore the wrong volume.
    let muted = MediaPlayerOptimistic.mute(playing(), muted: true)
    #expect(MediaPlayerState(muted).isMuted)
    #expect(MediaPlayerState(muted).volumePercent == 40)
    #expect(!MediaPlayerState(MediaPlayerOptimistic.mute(muted, muted: false)).isMuted)
}

@Test func optimisticSourceEchoesImmediately() {
    let after = MediaPlayerOptimistic.source(playing(), "TV")
    #expect(MediaPlayerState(after).source == "TV")
    // Nothing about the media is invented — what a source change does to playback is the device's
    // business, and guessing would put a title on screen that was never reported.
    #expect(MediaPlayerState(after).title == "So What")
}

@Test func poweringOffClearsEverythingItImplies() {
    // Flipping only `state` leaves a powered-down speaker rendering a full now-playing card — with
    // a *ticking* progress bar, since the position attributes it interpolates from are untouched.
    let off = MediaPlayerOptimistic.power(playing(), on: false)
    let s = MediaPlayerState(off)
    #expect(s.playback == .off)
    #expect(!s.isActive)
    #expect(s.title == nil)
    #expect(s.secondaryLine == nil)
    #expect(s.artworkPath == nil)
    #expect(s.duration == nil)
    #expect(!s.hasMedia)
    #expect(onScreenElapsed(off, at: t0.addingTimeInterval(600)) == nil)
    // Volume survives: switching a receiver off does not change how loud it will be next time.
    #expect(s.volumePercent == 40)
    // And the features are untouched, so the header keeps its power toggle to switch it back on.
    #expect(s.features.supportsPower)
}

@Test func poweringOnClaimsOnlyWhatIsKnown() {
    let e = EntityState(entityId: "media_player.kitchen", state: "off",
                        attributes: ["supported_features": .int(128 | 256)], lastUpdated: t0)
    let on = MediaPlayerOptimistic.power(e, on: true)
    let s = MediaPlayerState(on)
    #expect(s.playback == .on)
    #expect(s.isActive)
    // No media is invented for a device that hasn't answered yet.
    #expect(!s.hasMedia)
}
