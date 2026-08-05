import Testing
import AuthenticationServices
import Foundation
@testable import HavenApp

/// A stand-in for `ASWebAuthenticationSession` that never calls its completion handler unless the
/// test tells it to — the shape of a browser sheet sitting open, waiting for a person.
@MainActor
final class FakeAuthUISession: WebAuthUISession {
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    /// Set when the test wants `cancel()` to behave like the completion-firing variant, so both
    /// documented-ambiguous behaviours of the real API are covered.
    var completionFiresOnCancel = false
    let completion: @Sendable (URL?, (any Error)?) -> Void

    init(completion: @escaping @Sendable (URL?, (any Error)?) -> Void) {
        self.completion = completion
    }

    @discardableResult func start() -> Bool { startCount += 1; return true }

    func cancel() {
        cancelCount += 1
        if completionFiresOnCancel {
            completion(nil, ASWebAuthenticationSessionError(.canceledLogin))
        }
    }
}

/// Records that the awaiting task actually unwound, without anyone having to await it.
@MainActor final class Outcome { var finished = false }

@MainActor
@Suite struct WebAuthCancellationTests {
    /// Builds a presenter whose sessions the test can reach.
    private func makePresenter() -> (WebAuthPresenter, @MainActor () -> FakeAuthUISession?) {
        final class Box { var session: FakeAuthUISession? }
        let box = Box()
        let presenter = WebAuthPresenter { _, _, _, completion in
            let s = FakeAuthUISession(completion: completion)
            box.session = s
            return s
        }
        return (presenter, { box.session })
    }

    /// The defect this task exists for: cancelling the awaiting task must end the await.
    ///
    /// **Deliberately never awaits `auth`.** Before the fix that task is hung on a continuation
    /// nobody will resume, and anything that waits on it — `await auth.value`, `await auth.result`,
    /// or a task group containing either — inherits the hang and takes the whole suite down with
    /// it. Polling a flag the task sets on its own way out turns "it hung" into a failed
    /// expectation, which is the only form of this failure anyone can read.
    @Test func cancellingTheAwaitingTaskEndsTheAwaitRatherThanHanging() async throws {
        let (presenter, session) = makePresenter()
        let outcome = Outcome()

        let auth = Task { @MainActor in
            defer { outcome.finished = true }
            return try await presenter.authenticate(url: URL(string: "https://example.invalid/auth")!,
                                                    callbackScheme: "havenapp")
        }

        while session()?.startCount ?? 0 == 0 { await Task.yield() }
        auth.cancel()

        let deadline = ContinuousClock.now + .seconds(2)
        while !outcome.finished, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(outcome.finished, "authenticate() did not return after its task was cancelled — it hung")
        #expect(session()?.cancelCount == 1, "the browser sheet was left open")
    }

    /// `ASWebAuthenticationSession.cancel()`'s completion behaviour is not reliably documented, so
    /// the resume-once gate has to hold when cancelling *does* fire the completion handler. Without
    /// the gate this is a double resume, which traps rather than fails.
    ///
    /// Uses the same "never await a possibly-hung task" treatment as the test above: this is only
    /// safe to await once the fix is in (the completion firing is what resumes it), but in the RED
    /// state before the fix it has the identical hang hazard.
    @Test func cancellingSurvivesASessionThatAlsoFiresItsCompletionHandler() async throws {
        let (presenter, session) = makePresenter()
        let outcome = Outcome()

        let auth = Task { @MainActor in
            defer { outcome.finished = true }
            return try await presenter.authenticate(url: URL(string: "https://example.invalid/auth")!,
                                                    callbackScheme: "havenapp")
        }
        while session()?.startCount ?? 0 == 0 { await Task.yield() }
        session()?.completionFiresOnCancel = true

        auth.cancel()   // must not trap

        let deadline = ContinuousClock.now + .seconds(2)
        while !outcome.finished, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(outcome.finished, "authenticate() did not return after cancel()'s completion fired")
        #expect(session()?.cancelCount == 1)
    }

    /// The ordinary path still works: a callback URL is returned to the caller.
    @Test func asuccessfulCallbackIsReturned() async throws {
        let (presenter, session) = makePresenter()

        let auth = Task {
            try await presenter.authenticate(url: URL(string: "https://example.invalid/auth")!,
                                             callbackScheme: "havenapp")
        }
        while session()?.startCount ?? 0 == 0 { await Task.yield() }

        session()?.completion(URL(string: "havenapp://oauth/callback?code=abc")!, nil)

        let url = try await auth.value
        #expect(url.absoluteString == "havenapp://oauth/callback?code=abc")
    }
}
