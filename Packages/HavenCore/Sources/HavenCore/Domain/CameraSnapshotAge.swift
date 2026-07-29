import Foundation

/// How old the picture on screen is, in words.
///
/// The 2×2 tile stamps this over the bottom-right corner of its still and the 4×2 deliberately does
/// not — at four columns you can see the scene well enough to judge it, whereas at two the picture
/// is small enough that "is this now?" is a real question.
///
/// It exists as a pure function because "12s ago" is a claim about the user's home, and getting it
/// wrong is the exact failure this feature's whole design guards against: a picture that looks
/// live, isn't, and says nothing about the difference.
///
/// **The arithmetic is `RelativeAge`'s**; what belongs here is the optional `capturedAt` and the
/// "updated …" phrasing. Keeping the nil-handling on this side of the boundary is deliberate — see
/// `RelativeAge`, which refuses an optional precisely so that a caller with *no* measurement cannot
/// accidentally render it as "now".
public enum CameraSnapshotAge {
    public typealias Age = RelativeAge.Age

    /// The measured age, or `nil` when there is no frame yet *or* the frame is new enough to call
    /// live at this feature's refresh cadence.
    ///
    /// A `capturedAt` in the future — the phone and the instance disagreeing about the time —
    /// counts as "just now" rather than producing a negative age.
    public static func age(capturedAt: Date?, now: Date) -> Age? {
        guard let capturedAt else { return nil }
        return RelativeAge.age(of: capturedAt, now: now)
    }

    /// The compact stamp: `"12s ago"`, `"3m ago"`, `"2h ago"` — or `"just now"`, which is also what
    /// a frame that hasn't arrived at all would say, so callers pass `nil` for `capturedAt` only
    /// when they intend to show nothing at all instead.
    public static func describe(capturedAt: Date?, now: Date) -> String {
        guard let capturedAt else { return "just now" }
        return RelativeAge.describe(capturedAt, now: now)
    }

    /// The same measurement as a phrase for `accessibilityLabel`, where `"12s ago"` reads as a
    /// fragment and `"1 minutes"` reads as a bug.
    public static func spoken(capturedAt: Date?, now: Date) -> String {
        guard let capturedAt else { return "updated just now" }
        return "updated \(RelativeAge.spoken(capturedAt, now: now))"
    }
}
