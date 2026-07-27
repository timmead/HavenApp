import Foundation

/// What came back — or didn't — from one heartbeat ping.
///
/// `missed` covers *any* failure to get a pong within the deadline, not just a timeout: a send
/// that errored, a socket that closed underneath us, a `failAll` that resolved the ping with the
/// receive loop's error. All of them mean the same thing to the health decision — this ping did
/// not prove the connection is alive.
public enum PingOutcome: Sendable, Equatable {
    case pong
    case missed
}

/// The heartbeat's timing *and* its liveness rule, in one value.
///
/// **Why this exists as a value type rather than as timing buried in a `Task`:** the question the
/// heartbeat actually answers — "given the last few ping outcomes, is this connection dead?" — is
/// a pure one, and it decides whether the user gets a reconnect or keeps staring at stale lock
/// state. `HAWebSocketClient.startHeartbeat` supplies the clock; everything judgemental lives
/// here, where it can be tested without one.
///
/// **The numbers, and why.**
/// - `interval` (10s): unchanged from the original heartbeat. Cheap on battery, frequent enough
///   that a dead connection is noticed in tens of seconds rather than minutes.
/// - `timeout` (5s): how long a *single* ping may go unanswered before it counts as missed. Home
///   Assistant answers a ping in milliseconds on any working link; 5s is far beyond a slow
///   cellular round trip, so a ping that overruns it is genuinely anomalous rather than merely
///   slow. Crucially this is what makes the heartbeat *able to fail at all*: without it the ping's
///   continuation never resolves, the heartbeat task parks on that one `await` forever, and no
///   second ping is ever sent — a heartbeat whose only observable effect is to consume the first
///   ping.
/// - `tolerance` (2 consecutive misses): one missed pong on a mobile network is not proof of
///   death — a backgrounded radio, a handover, a momentary stall. Two consecutive misses spanning
///   ten seconds of silence, on a link that answers in milliseconds when healthy, is.
///
/// **Derived worst case: ~20s from fault onset to teardown.** A connection that goes half-open
/// immediately after a successful pong is idle for `interval` (10s), then burns `timeout` (5s) on
/// the first missed ping, then `timeout` again on the second (a miss retries immediately rather
/// than waiting out another full interval — see `delay(after:)`). Twenty seconds of stale state
/// before the reconnect UI appears is the price of not tearing down a healthy connection over one
/// bad round trip.
public struct HeartbeatPolicy: Sendable, Equatable {
    /// How long to wait after a *successful* pong before pinging again.
    public let interval: Duration
    /// How long one ping may go unanswered before it counts as `.missed`.
    public let timeout: Duration
    /// How many *consecutive* misses mean the connection is dead. Clamped to at least 1.
    public let tolerance: Int

    public init(interval: Duration = .seconds(10),
                timeout: Duration = .seconds(5),
                tolerance: Int = 2) {
        self.interval = interval
        self.timeout = timeout
        // Clamped, not trusted: `tolerance == 0` would make `isDead(recent: [])` true and declare
        // the connection dead before the first ping was ever sent — an instant reconnect loop over
        // a perfectly good socket.
        self.tolerance = Swift.max(1, tolerance)
    }

    /// **The decision.** Given the ping outcomes in the order they happened, is this connection
    /// dead?
    ///
    /// Counts *trailing consecutive* misses only: `[.missed, .pong, .missed]` is a link that
    /// stumbled and recovered, not a dead one, and must not be torn down. A single pong anywhere
    /// resets the count, because a pong is positive proof the far end is still processing frames.
    public func isDead(recent outcomes: [PingOutcome]) -> Bool {
        var consecutive = 0
        for outcome in outcomes.reversed() {
            guard outcome == .missed else { break }
            consecutive += 1
        }
        return consecutive >= tolerance
    }

    /// How long to wait before the *next* ping, given how the last one went.
    ///
    /// A miss retries immediately: the point of the remaining tolerance is to confirm or clear the
    /// suspicion quickly, and waiting out another full `interval` would push worst-case detection
    /// past half a minute for no extra confidence.
    public func delay(after outcome: PingOutcome) -> Duration {
        switch outcome {
        case .pong: return interval
        case .missed: return .zero
        }
    }
}

/// Rolling record of recent ping outcomes, paired with the policy that judges them.
///
/// A value type with no clock and no `Task`: `record` is the whole state machine, so the
/// "connection is dead" verdict can be driven frame by frame in a test rather than waited for.
/// Keeps only the last `tolerance` outcomes — nothing older can change a
/// trailing-consecutive-misses verdict.
public struct HeartbeatMonitor: Sendable, Equatable {
    public let policy: HeartbeatPolicy
    public private(set) var recent: [PingOutcome] = []

    public init(policy: HeartbeatPolicy = HeartbeatPolicy()) {
        self.policy = policy
    }

    /// Records one ping's outcome and returns whether the connection should now be considered dead.
    @discardableResult
    public mutating func record(_ outcome: PingOutcome) -> Bool {
        recent.append(outcome)
        if recent.count > policy.tolerance { recent.removeFirst(recent.count - policy.tolerance) }
        return policy.isDead(recent: recent)
    }

    /// Whether the outcomes recorded so far say the connection is dead.
    public var isDead: Bool { policy.isDead(recent: recent) }

    /// How long to wait before the next ping, given the most recent outcome (a full `interval`
    /// when nothing has been recorded yet, so a freshly-authenticated connection isn't pinged the
    /// instant it comes up).
    public var delayBeforeNextPing: Duration {
        policy.delay(after: recent.last ?? .pong)
    }
}
