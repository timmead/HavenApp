import Foundation

/// How long ago something happened, in words: `"just now"`, `"12s ago"`, `"3m ago"`, `"2h ago"`.
///
/// **It takes a `Date`, not a `Date?`, and that is the whole reason this type exists separately
/// from `CameraSnapshotAge`.** That type reads a nil capture time as "just now" — correct for it,
/// because a nil there means the frame on screen is the one being fetched right now, and its
/// callers guard the case where no frame exists at all. An event chip cannot borrow that: a nil
/// last-activation means *we do not know when this sensor last fired*, which is the opposite of
/// "now", and a type that could be handed nil would eventually be handed nil and would say
/// something false about the user's home. Not knowing is the caller's to render, and it cannot be
/// rendered by accident here.
///
/// `CameraSnapshotAge` keeps its own optional-taking surface and its "updated …" phrasing, and
/// delegates the arithmetic here so the two cannot drift into describing the same interval
/// differently.
public enum RelativeAge {
    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 3600

    /// Age split into a number and its unit, so a compact stamp and a spoken phrase are two
    /// renderings of one measurement rather than two measurements that have to agree.
    public struct Age: Sendable, Equatable {
        public enum Unit: Sendable, Equatable { case seconds, minutes, hours }
        public let value: Int
        public let unit: Unit
    }

    /// The measured age, or `nil` when it is too recent to be worth counting.
    ///
    /// A date in the future — the phone and the Home Assistant instance disagreeing about the time,
    /// which happens — counts as "just now" rather than producing a negative age.
    public static func age(of date: Date, now: Date) -> Age? {
        let interval = now.timeIntervalSince(date)
        // Under two seconds is "just now" in any of this app's vocabularies, and "1s ago" ticking
        // to "2s ago" is motion for its own sake.
        guard interval >= 2 else { return nil }
        if interval < minute { return Age(value: Int(interval), unit: .seconds) }
        if interval < hour { return Age(value: Int(interval / minute), unit: .minutes) }
        return Age(value: Int(interval / hour), unit: .hours)
    }

    /// The compact form: `"12s ago"`, `"3m ago"`, `"2h ago"`, or `"just now"`.
    public static func describe(_ date: Date, now: Date) -> String {
        guard let age = age(of: date, now: now) else { return "just now" }
        switch age.unit {
        case .seconds: return "\(age.value)s ago"
        case .minutes: return "\(age.value)m ago"
        case .hours: return "\(age.value)h ago"
        }
    }

    /// The same measurement as a phrase for `accessibilityLabel`, where `"12s ago"` reads as a
    /// fragment and `"1 minutes"` reads as a bug.
    public static func spoken(_ date: Date, now: Date) -> String {
        guard let age = age(of: date, now: now) else { return "just now" }
        let unit: String
        switch age.unit {
        case .seconds: unit = age.value == 1 ? "second" : "seconds"
        case .minutes: unit = age.value == 1 ? "minute" : "minutes"
        case .hours: unit = age.value == 1 ? "hour" : "hours"
        }
        return "\(age.value) \(unit) ago"
    }
}
