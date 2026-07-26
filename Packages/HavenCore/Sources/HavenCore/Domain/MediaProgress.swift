import Foundation

/// Where a track actually is *now*.
///
/// Home Assistant publishes `media_position` together with `media_position_updated_at` and then
/// says nothing more until something changes — it does not re-report the position every second.
/// So a renderer that draws `media_position` directly shows a progress bar frozen wherever the
/// last state push left it, which looks exactly like a working feature and is the reason this
/// interpolation is here, in HavenCore, under test, rather than inline in a SwiftUI body.
///
/// Two properties are load-bearing and both are tested:
/// - **It stops when paused.** A paused player's `media_position_updated_at` recedes into the past
///   while the position stays put; adding the elapsed wall-clock time to it would race the bar to
///   the end of a track nobody is playing.
/// - **It never runs backwards or past the end.** Clock skew between the phone and the instance
///   can put `now` *before* `updatedAt`, and a long-running interpolation will overshoot a
///   `media_duration` that stopped being updated; both clamp.
public enum MediaProgress {
    /// Seconds into the track at `now`, or `nil` when the device reports no position at all.
    ///
    /// `now` is ignored entirely unless the player is playing and reported when its position was
    /// taken — those are the only conditions under which time may be added to it.
    public static func elapsed(
        position: Double?,
        updatedAt: Date?,
        isPlaying: Bool,
        duration: Double?,
        now: Date
    ) -> Double? {
        guard let position else { return nil }
        let base = max(0, position)
        guard isPlaying, let updatedAt else { return clamp(base, duration: duration) }
        // A negative interval means the two clocks disagree, not that the track went backwards.
        let delta = max(0, now.timeIntervalSince(updatedAt))
        return clamp(base + delta, duration: duration)
    }

    /// `elapsed / duration` in 0…1, or `nil` when there is nothing meaningful to divide — no
    /// position, no duration, or a duration of zero (a live radio stream reports exactly this, and
    /// dividing by it would produce a NaN width that lays out as a garbage bar rather than as no
    /// bar at all).
    public static func fraction(elapsed: Double?, duration: Double?) -> Double? {
        guard let elapsed, let duration, duration > 0 else { return nil }
        return min(1, max(0, elapsed / duration))
    }

    /// `m:ss`, or `h:mm:ss` past an hour. Anything negative or non-finite reads as `0:00` rather
    /// than as a minus sign in the corner of the now-playing card.
    public static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let s = total % 60, m = (total / 60) % 60, h = total / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Parses `media_position_updated_at`.
    ///
    /// Home Assistant serializes it with `datetime.isoformat()`, giving **microsecond** precision
    /// (`2026-07-26T10:00:00.123456+00:00`). That matters: `ISO8601DateFormatter` is configured
    /// with an explicit set of options and returns `nil` for a string that doesn't match them, so a
    /// parser that only knows one shape silently yields no timestamp — and a nil timestamp here
    /// means the bar never ticks, which is precisely the frozen-progress bug this file exists to
    /// prevent, reintroduced through the back door. The statistics `start` field had exactly this
    /// failure (D spec §10a); this accepts every shape rather than guessing which one arrives.
    ///
    /// The numeric branch (epoch seconds) is defensive only — no Home Assistant version is known to
    /// send one — and is preferred over silently returning `nil` for a value that plainly is a time.
    public static func parseUpdatedAt(_ value: JSONValue?) -> Date? {
        guard let value else { return nil }
        if let seconds = value.asDouble { return Date(timeIntervalSince1970: seconds) }
        guard let raw = value.asString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if let d = fractional.date(from: raw) { return d }
        if let d = plain.date(from: raw) { return d }
        // Sub-second precision beyond three digits, which the fractional formatter rejects on some
        // OS versions: drop the fraction and re-try rather than lose the whole timestamp over it.
        if let d = plain.date(from: strippingFractionalSeconds(raw)) { return d }
        return nil
    }

    /// The text an optimistic write puts back into `media_position_updated_at`, in the same shape
    /// Home Assistant uses — so the value round-trips through `parseUpdatedAt` and an optimistic
    /// pause is indistinguishable (to every later reader) from one the instance reported itself.
    public static func formatUpdatedAt(_ date: Date) -> String {
        fractional.string(from: date)
    }

    private static func clamp(_ value: Double, duration: Double?) -> Double {
        guard let duration, duration > 0 else { return max(0, value) }
        return min(max(0, value), duration)
    }

    /// `2026-07-26T10:00:00.123456+00:00` → `2026-07-26T10:00:00+00:00`.
    private static func strippingFractionalSeconds(_ s: String) -> String {
        guard let dot = s.firstIndex(of: ".") else { return s }
        let rest = s[s.index(after: dot)...]
        guard let end = rest.firstIndex(where: { !$0.isNumber }) else { return String(s[..<dot]) }
        return String(s[..<dot]) + String(rest[end...])
    }

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
