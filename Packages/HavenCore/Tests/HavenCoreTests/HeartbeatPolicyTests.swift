import Testing
import Foundation
@testable import HavenCore

/// The heartbeat's liveness rule, exercised without a clock.
///
/// This is the decision that separates "the connection stalled for a moment" from "the connection
/// is dead, tear it down and reconnect" — the one the user feels as either a spurious reconnect on
/// a flaky train journey or a dashboard frozen on stale lock state. It is a pure function
/// precisely so it can be pinned here rather than inferred from timing in a `Task`.
@Suite struct HeartbeatPolicyTests {
    private let policy = HeartbeatPolicy(interval: .seconds(10), timeout: .seconds(5), tolerance: 2)

    @Test func aConnectionWithNoPingsYetIsNotDead() {
        // The window is empty for the whole first interval after authenticating. Reading that as
        // death would tear down every connection the moment it came up.
        #expect(policy.isDead(recent: []) == false)
    }

    @Test func oneMissedPongIsNotProofOfDeath() {
        // A backgrounded radio, a Wi-Fi/cellular handover, a momentary stall — all produce exactly
        // this and all recover on their own.
        #expect(policy.isDead(recent: [.missed]) == false)
    }

    @Test func twoConsecutiveMissedPongsMeanDead() {
        #expect(policy.isDead(recent: [.missed, .missed]))
        #expect(policy.isDead(recent: [.pong, .missed, .missed]))
    }

    @Test func onlyTrailingMissesCount() {
        // The distinguishing case: a link that stumbled and recovered. If misses were merely
        // counted rather than counted *consecutively*, any connection would eventually accumulate
        // enough of them to be killed mid-session over nothing.
        #expect(policy.isDead(recent: [.missed, .pong, .missed]) == false)
        #expect(policy.isDead(recent: [.missed, .missed, .pong]) == false)
    }

    @Test func toleranceOfOneDeclaresDeathOnTheFirstMiss() {
        let strict = HeartbeatPolicy(interval: .seconds(10), timeout: .seconds(5), tolerance: 1)
        #expect(strict.isDead(recent: [.missed]))
        #expect(strict.isDead(recent: []) == false)
    }

    @Test func toleranceIsClampedSoZeroCannotDeclareAHealthyConnectionDead() {
        // Unclamped, `isDead(recent: [])` would be vacuously true (zero trailing misses >= zero)
        // and every connection would be torn down before its first ping ever went out.
        let clamped = HeartbeatPolicy(tolerance: 0)
        #expect(clamped.tolerance == 1)
        #expect(clamped.isDead(recent: []) == false)
        #expect(clamped.isDead(recent: [.missed]))
    }

    @Test func aMissRetriesImmediatelyAndAPongWaitsOutTheInterval() {
        // This pairing is what makes worst-case detection ~20s rather than ~30s: once a ping is
        // missed the remaining tolerance exists to confirm or clear the suspicion quickly.
        #expect(policy.delay(after: .pong) == .seconds(10))
        #expect(policy.delay(after: .missed) == .zero)
    }

    @Test func theMonitorReportsDeathOnTheRecordThatCrossesTheThreshold() {
        var monitor = HeartbeatMonitor(policy: policy)
        let afterPong = monitor.record(.pong)
        let afterFirstMiss = monitor.record(.missed)
        let afterSecondMiss = monitor.record(.missed)
        #expect(afterPong == false)
        #expect(afterFirstMiss == false)
        #expect(afterSecondMiss)
        #expect(monitor.isDead)
    }

    @Test func aPongClearsAnEarlierMiss() {
        var monitor = HeartbeatMonitor(policy: policy)
        let afterMiss = monitor.record(.missed)
        let afterPong = monitor.record(.pong)
        let afterSecondMiss = monitor.record(.missed)   // one trailing miss, not two
        #expect(afterMiss == false)
        #expect(afterPong == false)
        #expect(afterSecondMiss == false)
        #expect(monitor.isDead == false)
    }

    @Test func theMonitorKeepsOnlyAsMuchHistoryAsTheVerdictCanUse() {
        var monitor = HeartbeatMonitor(policy: policy)
        for _ in 0..<50 { _ = monitor.record(.pong) }
        #expect(monitor.recent.count <= policy.tolerance)
        #expect(monitor.isDead == false)
    }

    @Test func aFreshMonitorWaitsAFullIntervalBeforeItsFirstPing() {
        let monitor = HeartbeatMonitor(policy: policy)
        #expect(monitor.delayBeforeNextPing == .seconds(10))
    }

    @Test func theShippedDefaultsAreTheOnesDocumented() {
        // Pinned because the ~20s worst-case detection quoted in `HeartbeatPolicy` (and in the
        // commit that introduced it) is derived from exactly these three numbers.
        let shipped = HeartbeatPolicy()
        #expect(shipped.interval == .seconds(10))
        #expect(shipped.timeout == .seconds(5))
        #expect(shipped.tolerance == 2)
    }
}
