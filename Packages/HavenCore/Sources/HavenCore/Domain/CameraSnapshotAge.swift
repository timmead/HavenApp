import Foundation

/// How old the picture on screen is, in words.
///
/// The 2×2 tile carries this stamp and the 4×2 one deliberately does not — at four columns the
/// still fills the tile and a stamp over it would be furniture, whereas at two columns the caption
/// strip is the only thing saying whether you are looking at now or at ten minutes ago.
///
/// It exists as a pure function because "12s ago" is a claim about the user's home, and getting it
/// wrong is the exact failure this feature's whole design guards against: a picture that looks
/// live, isn't, and says nothing about the difference.
public enum CameraSnapshotAge {
    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 3600

    /// Age split into a number and its unit, so the compact stamp and the spoken phrase are two
    /// renderings of one measurement rather than two measurements that have to agree.
    public struct Age: Sendable, Equatable {
        public enum Unit: Sendable, Equatable { case seconds, minutes, hours }
        public let value: Int
        public let unit: Unit
    }

    /// The measured age, or `nil` when there is no frame yet *or* the frame is new enough to call
    /// live at this feature's refresh cadence.
    ///
    /// A `capturedAt` in the future — the phone and the instance disagreeing about the time —
    /// counts as "just now" rather than producing a negative age.
    public static func age(capturedAt: Date?, now: Date) -> Age? {
        guard let capturedAt else { return nil }
        let interval = now.timeIntervalSince(capturedAt)
        // Under two seconds is indistinguishable from live at a ten-second refresh, and "1s ago"
        // ticking to "2s ago" is motion for its own sake on a dashboard glanced at for two seconds.
        guard interval >= 2 else { return nil }
        if interval < minute { return Age(value: Int(interval), unit: .seconds) }
        if interval < hour { return Age(value: Int(interval / minute), unit: .minutes) }
        return Age(value: Int(interval / hour), unit: .hours)
    }

    /// The compact stamp for the caption strip: `"12s ago"`, `"3m ago"`, `"2h ago"` — or
    /// `"just now"`, which is also what a frame that hasn't arrived at all would say, so callers
    /// pass `nil` for `capturedAt` only when they intend to show nothing at all instead.
    public static func describe(capturedAt: Date?, now: Date) -> String {
        guard let age = age(capturedAt: capturedAt, now: now) else { return "just now" }
        switch age.unit {
        case .seconds: return "\(age.value)s ago"
        case .minutes: return "\(age.value)m ago"
        case .hours: return "\(age.value)h ago"
        }
    }

    /// The same measurement as a phrase for `accessibilityLabel`, where `"12s ago"` reads as a
    /// fragment and `"1 minutes"` reads as a bug.
    public static func spoken(capturedAt: Date?, now: Date) -> String {
        guard let age = age(capturedAt: capturedAt, now: now) else { return "updated just now" }
        let unit: String
        switch age.unit {
        case .seconds: unit = age.value == 1 ? "second" : "seconds"
        case .minutes: unit = age.value == 1 ? "minute" : "minutes"
        case .hours: unit = age.value == 1 ? "hour" : "hours"
        }
        return "updated \(age.value) \(unit) ago"
    }
}
