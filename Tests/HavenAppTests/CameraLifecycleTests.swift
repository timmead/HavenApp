import Testing
import Foundation
import HavenCore
@testable import HavenApp

/// **Regression 1: the still-refresh loop that cancelled its own in-flight fetch.**
///
/// The first version drove refreshes from an external counter that a sibling task bumped once a
/// second; because the counter was part of `.task`'s id, every tick cancelled whatever fetch was in
/// flight. Wherever a round trip reliably took longer than the interval — a Nabu Casa relay, a 4K
/// still, a slow `camera_proxy` — **no fetch ever completed**. `.cancelled` maps to "change
/// nothing", so the phase stayed `.loading` forever: a permanent black rectangle, bought with one
/// cancelled full-resolution JPEG request per second. Nothing failed, so nothing was logged and
/// nothing was visible except a camera that never appeared.
///
/// The property that makes it impossible is that the next fetch is started by the previous one
/// *finishing*. These run the real cycle with an injected clock and an injected wait, so a slow link
/// costs no wall-clock time and no test races on one.
@Suite @MainActor struct SnapshotRefreshCycleTests {
    /// Records what the cycle did, and holds the simulated clock and the task handle.
    ///
    /// A `@MainActor` class because the cycle is `@MainActor` and so is everything here — no locks,
    /// no second thread, and therefore nothing in the *test* that could produce the interleaving it
    /// is trying to rule out.
    ///
    /// The cycle is stopped from **inside** `load`, by cancelling the enclosing task once enough
    /// rounds have happened, rather than by a bystander polling `finished`. That is deliberate: the
    /// loop's only suspension points are the ones it actually has, so a test that waited from
    /// outside would depend on the loop yielding at some particular moment — and would hang, not
    /// fail, when it didn't.
    @MainActor private final class Recorder {
        var started = 0
        var finished = 0
        var inFlight = 0
        var maxInFlight = 0
        var wasCancelledDuringALoad = false
        var delays: [TimeInterval] = []
        var clock = Date(timeIntervalSince1970: 0)
        var task: Task<Void, Never>?

        func stopAfter(_ rounds: Int) { if finished >= rounds { task?.cancel() } }
    }

    /// **The defect, directly.** Each load takes 25 simulated seconds against a 10-second interval
    /// — the exact "round trip reliably exceeds the interval" case that used to produce a permanent
    /// placeholder. Every load must still run to completion, and none may be cancelled part-way.
    @Test func aLoadSlowerThanTheIntervalStillCompletes() async {
        let recorder = Recorder()
        let task = Task { @MainActor [recorder] in
            await AuthenticatedImageRefreshCycle.run(
                AuthenticatedImageRefresh(interval: 10),
                now: { recorder.clock },
                sleep: { recorder.delays.append($0); await Task.yield() },
                load: {
                    recorder.started += 1
                    recorder.inFlight += 1
                    recorder.maxInFlight = max(recorder.maxInFlight, recorder.inFlight)
                    // A fetch that takes 25s of the cycle's own clock, with real suspension points
                    // in the middle — the windows the old external ticker used to cancel through.
                    for _ in 0..<4 { await Task.yield() }
                    recorder.clock = recorder.clock.addingTimeInterval(25)
                    if Task.isCancelled { recorder.wasCancelledDuringALoad = true }
                    recorder.inFlight -= 1
                    recorder.finished += 1
                    recorder.stopAfter(3)
                }
            )
        }
        recorder.task = task
        await task.value

        #expect(recorder.started == 3)
        #expect(recorder.finished == recorder.started, "every fetch that started must have finished")
        #expect(!recorder.wasCancelledDuringALoad, "nothing may cancel a fetch that is in flight")
        #expect(recorder.maxInFlight == 1, "the next fetch starts only once the previous one finished")
        // A fetch already slower than its interval degrades to the floor gap — not to a busy loop,
        // and not to a negative (i.e. absent) wait.
        #expect(recorder.delays == [SnapshotRefresh.minimumGap, SnapshotRefresh.minimumGap])
    }

    /// A fast link holds the target cadence measured start-to-start, so the rate doesn't drift by
    /// the fetch time on every cycle.
    @Test func aFastLoadWaitsOutTheRemainderOfTheInterval() async {
        let recorder = Recorder()
        let task = Task { @MainActor [recorder] in
            await AuthenticatedImageRefreshCycle.run(
                AuthenticatedImageRefresh(interval: 10),
                now: { recorder.clock },
                sleep: { recorder.delays.append($0); await Task.yield() },
                load: {
                    recorder.started += 1
                    recorder.clock = recorder.clock.addingTimeInterval(2)
                    recorder.finished += 1
                    recorder.stopAfter(3)
                }
            )
        }
        recorder.task = task
        await task.value

        #expect(recorder.delays == [8, 8])
    }

    /// **Where the refresh stops.** `isActive` goes false when the app backgrounds; the cycle must
    /// then do nothing at all rather than keep pulling frames off the user's own server while the
    /// app is off screen.
    @Test func anInactivePolicyNeverLoads() async {
        let recorder = Recorder()
        await AuthenticatedImageRefreshCycle.run(
            AuthenticatedImageRefresh(interval: 10, isActive: false),
            now: { recorder.clock },
            sleep: { recorder.delays.append($0) },
            load: { recorder.started += 1 }
        )
        #expect(recorder.started == 0)
        #expect(recorder.delays.isEmpty)
    }

    /// Cancellation is observed after the load and before the wait, so a cancelled cycle neither
    /// waits nor starts another fetch — `.task`'s cancellation on disappear ends it immediately.
    @Test func cancellationEndsTheCycleWithoutAnotherFetch() async {
        let recorder = Recorder()
        let task = Task { @MainActor [recorder] in
            await AuthenticatedImageRefreshCycle.run(
                AuthenticatedImageRefresh(interval: 10),
                now: { recorder.clock },
                sleep: { recorder.delays.append($0); await Task.yield() },
                load: {
                    recorder.started += 1
                    recorder.finished += 1
                    recorder.stopAfter(1)
                }
            )
        }
        recorder.task = task
        await task.value

        #expect(recorder.started == 1)
        #expect(recorder.delays.isEmpty, "a cancelled cycle must not wait, it must return")
    }
}

/// **Regression 2: an `AVPlayer` created and started after teardown had already run.**
///
/// `HAWebSocketClient.request` is a bare continuation with no cancellation handling, so cancelling
/// the camera modal's task does not cancel the in-flight `camera/stream` command — Home Assistant
/// answers whenever its stream worker is ready (a second or more for a Protect camera) and the
/// resolution then resumes. A user who opened a camera and swiped the sheet away before it resolved
/// got a player built *after* `onDisappear`: no owner, no path to being stopped, and pulling HLS
/// segments from a camera inside their home from that moment on. A battery drain and a privacy
/// problem in the same breath, in the one place the plan calls both out.
///
/// `CameraPlaybackPlan.resolve` is the decision, and `.cancelled` is the outcome that touches
/// nothing. `CameraModal.start` constructs a player only inside the `.show(.hls)` branch, so these
/// cover the two windows where cancellation can land.
@Suite @MainActor struct CameraPlaybackPlanTests {
    private func camera(_ state: String = "idle") -> CameraState {
        CameraState(EntityState(
            entityId: "camera.porch",
            state: state,
            attributes: ["supported_features": .int(2), "frontend_stream_type": .string("hls")],
            lastUpdated: Date()
        ))
    }

    private let baseURL = URL(string: "http://192.168.1.20:8123")!

    /// Cancelled while `camera/stream` was still outstanding — the sheet was swiped away. Nothing
    /// is shown, and, crucially, nothing is built.
    @Test func cancellationWhileTheStreamCommandIsOutstandingBuildsNothing() async {
        var cancelled = false
        var baseURLWasRead = false
        let plan = await CameraPlaybackPlan.resolve(
            state: camera(),
            isCancelled: { cancelled },
            streamPath: {
                // Home Assistant answers late; by then the modal is gone.
                cancelled = true
                return "/api/hls/token/master.m3u8"
            },
            baseURL: { baseURLWasRead = true; return self.baseURL }
        )
        #expect(plan == .cancelled)
        #expect(!baseURLWasRead, "resolution must stop at the first cancellation check, not carry on")
    }

    /// The second window: the command came back in time, but the session's address was still being
    /// read when the view went away.
    @Test func cancellationWhileTheBaseURLIsBeingReadBuildsNothing() async {
        var cancelled = false
        let plan = await CameraPlaybackPlan.resolve(
            state: camera(),
            isCancelled: { cancelled },
            streamPath: { "/api/hls/token/master.m3u8" },
            baseURL: { cancelled = true; return self.baseURL }
        )
        #expect(plan == .cancelled)
    }

    /// The ordinary success: a playlist resolved against the address the session is using *now*,
    /// which is the only case that gets a player.
    @Test func aResolvedPlaylistIsTheOnlyOutcomeThatGetsAPlayer() async {
        let plan = await CameraPlaybackPlan.resolve(
            state: camera(),
            isCancelled: { false },
            streamPath: { "/api/hls/token/master.m3u8" },
            baseURL: { self.baseURL }
        )
        #expect(plan == .show(.hls(URL(string: "http://192.168.1.20:8123/api/hls/token/master.m3u8")!)))
    }

    /// No stream available falls back to the faster still refresh rather than to an error — a
    /// working live view, just a slower one — and no player is created for it.
    @Test func noStreamFallsBackToStillsRatherThanFailing() async {
        let plan = await CameraPlaybackPlan.resolve(
            state: camera(),
            isCancelled: { false },
            streamPath: { nil },
            baseURL: { self.baseURL }
        )
        #expect(plan == .show(.snapshotRefresh))
    }

    /// Signed out, or failed over to nothing: there is no address to resolve a playlist against, and
    /// a playlist resolved against the wrong host plays as a black rectangle with no error anywhere.
    @Test func noBaseURLIsUnavailableRatherThanAGuess() async {
        let plan = await CameraPlaybackPlan.resolve(
            state: camera(),
            isCancelled: { false },
            streamPath: { "/api/hls/token/master.m3u8" },
            baseURL: { nil }
        )
        #expect(plan == .show(.unavailable))
    }

    /// An entity Home Assistant isn't reporting at all. Resolved without asking for a stream, and
    /// without reading the session address.
    @Test func anAbsentEntityIsUnavailableWithoutAskingAnything() async {
        var asked = false
        let plan = await CameraPlaybackPlan.resolve(
            state: nil,
            isCancelled: { false },
            streamPath: { asked = true; return nil },
            baseURL: { asked = true; return self.baseURL }
        )
        #expect(plan == .show(.unavailable))
        #expect(!asked)
    }
}
