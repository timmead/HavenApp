import os

/// App-wide logger for connection diagnostics. Visible in Console/Xcode, quiet in
/// release builds, and never carries token material.
let havenLog = Logger(subsystem: "app.haven.HavenApp", category: "connection")

/// Stage timings for one connection attempt.
///
/// **"Connecting takes several retries" is not a diagnosable report**, and that is the whole reason
/// this exists. The remedy is completely different depending on where the seconds actually go —
/// resolving a name, the TCP/TLS handshake, waiting on Home Assistant's `auth_ok`, or the four
/// registry round trips in `bootstrap()` — and the logs previously said only which candidate failed
/// and with what error, never how long any of it took. The first real bug this hunted (a `.waiting`
/// DNS result being treated as terminal, failing candidates in 15ms) was invisible in the log
/// precisely because 15ms and 2s produced identical lines.
///
/// Deliberately wall-clock and deliberately coarse: this is for reading in Console while standing
/// in a kitchen, not for benchmarking. `ContinuousClock` so it is unaffected by the clock being
/// adjusted mid-connect, which on a device that has just woken is not hypothetical.
struct ConnectTiming {
    private let start = ContinuousClock.now
    private var previous = ContinuousClock.now
    private var marks: [String] = []

    /// Records the time since the previous mark (or since creation, for the first).
    mutating func mark(_ stage: String) {
        let now = ContinuousClock.now
        marks.append("\(stage)=\(Self.ms(previous.duration(to: now)))")
        previous = now
    }

    /// Every stage, plus the total — the one string the caller logs.
    var summary: String {
        (marks + ["total=\(Self.ms(start.duration(to: .now)))"]).joined(separator: " ")
    }

    private static func ms(_ d: Duration) -> String {
        let milliseconds = Double(d.components.seconds) * 1000
            + Double(d.components.attoseconds) / 1_000_000_000_000_000
        return "\(Int(milliseconds.rounded()))ms"
    }
}
