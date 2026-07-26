import Foundation

/// The local state a media-player command implies, applied before Home Assistant confirms it.
///
/// Pure `EntityState → EntityState` and here rather than in `HomeStore` for one reason: **an
/// optimistic update has to flip every attribute it implies, not just the obvious one.** The
/// previous instance of that bug in this project left a brightness slider reading a stale value
/// after a light was switched off. The media player's version is worse than stale — it is
/// *animated*: pausing writes `playing → paused`, but if `media_position`/
/// `media_position_updated_at` are left alone, `MediaProgress` still holds the position recorded
/// when playback started, so the bar visibly jumps backwards at the moment of the pause and then
/// jumps forwards again when Home Assistant's echo lands. Every function here rewrites the whole
/// implied set, and the tests assert the resulting state through `MediaProgress`, not
/// attribute-by-attribute, so a missed attribute shows up as a jump rather than as a passing test.
public enum MediaPlayerOptimistic {
    /// Play ⇄ pause. Freezes the interpolated position at `now` and restamps
    /// `media_position_updated_at`, so the bar continues from exactly where it was on screen —
    /// whether it is stopping there (pause) or resuming from there (play).
    public static func playPause(_ e: EntityState, now: Date) -> EntityState {
        let s = MediaPlayerState(e)
        let elapsed = MediaProgress.elapsed(
            position: s.position, updatedAt: s.positionUpdatedAt,
            isPlaying: s.isPlaying, duration: s.duration, now: now
        )
        var next = e
        next.state = s.isPlaying
            ? MediaPlayerState.Playback.paused.rawValue
            : MediaPlayerState.Playback.playing.rawValue
        // Restamped in both directions. Pausing without this leaves a stale `updatedAt` that the
        // *next* play would interpolate from; playing without it resumes from an `updatedAt` that
        // is minutes old and jumps the bar forward by however long the pause lasted.
        if let elapsed {
            next.attributes["media_position"] = .double(elapsed)
            next.attributes["media_position_updated_at"] = .string(MediaProgress.formatUpdatedAt(now))
        }
        return next
    }

    /// `volume_set`. Percent in, `volume_level` (0…1) out — the same round-trip
    /// `MediaPlayerState.volumePercent` reads back, so a slider released at 37 stays at 37 instead
    /// of snapping to whatever rounding the two conversions would otherwise disagree on.
    public static func volume(_ e: EntityState, percent: Int) -> EntityState {
        var next = e
        next.attributes["volume_level"] = .double(Double(max(0, min(100, percent))) / 100)
        return next
    }

    /// `volume_mute`. Muting deliberately leaves `volume_level` alone: Home Assistant's mute is
    /// independent of level, and zeroing it here would make un-muting restore the wrong volume.
    public static func mute(_ e: EntityState, muted: Bool) -> EntityState {
        var next = e
        next.attributes["is_volume_muted"] = .bool(muted)
        return next
    }

    /// `select_source`. Source is echoed immediately so the segmented control moves under the
    /// finger; nothing else is implied, since what a source change does to the *media* is the
    /// device's business and inventing a title here would be a guess.
    public static func source(_ e: EntityState, _ source: String) -> EntityState {
        var next = e
        next.attributes["source"] = .string(source)
        return next
    }

    /// `turn_on` / `turn_off`.
    ///
    /// Off clears the whole now-playing set, not just the state string: a powered-down speaker
    /// still carrying `media_title`, artwork and a position would keep rendering a now-playing
    /// card — with a *ticking* progress bar, since the paused/playing check reads the state we just
    /// changed but the position attributes it interpolates from would be untouched.
    ///
    /// On writes `on` rather than `idle` or `playing`: it is the one state that says "powered, and
    /// we don't know more than that", and no attribute can be honestly invented for a device that
    /// hasn't answered yet. Whichever of `on`/`idle`/`playing` the integration actually reports
    /// arrives moments later and replaces this wholesale.
    public static func power(_ e: EntityState, on: Bool) -> EntityState {
        var next = e
        next.state = on ? MediaPlayerState.Playback.on.rawValue : MediaPlayerState.Playback.off.rawValue
        guard !on else { return next }
        for key in ["media_title", "media_artist", "media_album_name", "app_name",
                    "entity_picture", "media_position", "media_position_updated_at",
                    "media_duration", "source"] {
            next.attributes.removeValue(forKey: key)
        }
        return next
    }
}
