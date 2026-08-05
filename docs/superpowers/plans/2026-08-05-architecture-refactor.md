# Architecture Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute the sequence in `2026-08-05-architecture-review.md` — close the concurrency
defects, make session lifetime explicit, and re-split the two files that regrew — without changing
observable app behaviour.

**Architecture:** The app keeps its current pattern: shared `@Observable` stores reached through
the SwiftUI environment, over the `HavenCore` package where all policy lives under test. Nothing
here is a pattern migration. Every task is decomposition or lifetime work inside that pattern.

**Tech Stack:** Swift 6.0 (language mode v6, strict concurrency `complete`), iOS 26.0 minimum,
SwiftUI + Observation, Swift Testing (`import Testing`), XcodeGen (`project.yml` generates the
`.xcodeproj`), no third-party dependencies.

## Global Constraints

- **No third-party dependencies.** Networking is `URLSession`/`Network.framework` only. The only
  SPM dependency is the local `Packages/HavenCore`.
- **Policy lives in HavenCore under test; `App/` glues and renders.** No decision may move *into* a
  view. No `import SwiftUI`/`import UIKit` may appear in `Packages/HavenCore`.
- **Comment loss is a failing check.** Long comments in this codebase encode a bug that already
  shipped and why the current shape prevents its return. A refactor that deletes rationale passes
  every test and is a real regression. Every comment on moved code moves *with* it. If a comment
  is deleted, its justification must be stated in the commit message.
- **A new test is not finished until it has been watched to fail.** Break the production code it
  covers, watch it go red, restore the code with `git checkout`/`git diff` (not from memory), then
  commit. Report the mutation and the observed failure in the task report.
- **Both suites green before every commit:**
  - `swift test --package-path Packages/HavenCore` (baseline: 788 tests, 18 suites)
  - `xcodebuild test -scheme HavenApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
    (baseline: 107 tests, 21 suites)
- **One refactor per commit.** Never bundle unrelated changes.
- **Adding or moving a file under `App/` requires `xcodegen generate` afterwards**, because
  `project.yml` is the source of truth for the Xcode project, not the `.pbxproj`.
- **Swift Testing only.** `import Testing`, `@Suite`, `@Test`, `#expect`, `#require`. There is no
  XCTest anywhere in this repo; do not introduce it.
- **Never touch the real Keychain or `UserDefaults.standard` from a test.** The app-layer test
  bundle is hosted *inside the real app process*. Use `makeTestDefaults(_:)` and `FakeTokenStore`
  from `Tests/HavenAppTests/Fakes.swift`.
- **Do not "tidy" `BulkActionRunner.run`.** Its isolation shape is a documented compiler-limitation
  workaround (`App/BulkActionRunner.swift:59-70`).

---

### Task 1: Make web authentication cancellation-safe

**Context.** `WebAuthPresenter.authenticate` wraps `ASWebAuthenticationSession` in
`withCheckedThrowingContinuation` with no cancellation handling. If the awaiting task is cancelled
while the auth sheet is open, the continuation is never resumed and that task hangs forever.
`AppModel.signIn()` awaits this, and `signOut()`/`requireReauthentication()` cancel `connectTask`,
so a hang here is reachable in the shipping app.

**Two things make this subtler than it looks, and both must be handled:**

1. The `ASWebAuthenticationSession` is created *inside* a nested `Task { @MainActor in … }`, so a
   cancellation handler installed outside it has no reference to the session to cancel. The session
   must be hoisted into a `@MainActor` box the handler can reach.
2. Whether `ASWebAuthenticationSession.cancel()` invokes the completion handler is **not reliably
   documented**. The design must therefore be correct under *both* behaviours: if `cancel()` does
   fire the completion, the continuation must not be resumed a second time (a double resume is a
   crash, not a warning). **Route every resume through one resume-once gate.** Do not assume either
   behaviour; assume both are possible.

**Files:**
- Modify: `App/WebAuthPresenter.swift` (whole file, currently 26 lines)
- Create: `Tests/HavenAppTests/WebAuthCancellationTests.swift`

**Interfaces:**
- Consumes: `WebAuthSession` (protocol in `Packages/HavenCore/Sources/HavenCore/Auth/WebAuthSession.swift`)
  — `WebAuthPresenter`'s conformance signature `nonisolated func authenticate(url: URL, callbackScheme: String) async throws -> URL` must not change, because `OAuthClient.login(baseURL:web:http:)` calls it through the protocol.
- Produces: `WebAuthUISession` (new protocol) and `WebAuthPresenter.init(makeSession:)` (new
  injectable factory, defaulted to the real `ASWebAuthenticationSession`). No other file's call
  sites change: `AppModel` keeps `private let web = WebAuthPresenter()`.

- [ ] **Step 1: Add the seam protocol and the injectable factory**

The presenter currently constructs `ASWebAuthenticationSession` inline, which is why no test can
reach the cancellation path. Add the smallest protocol that covers what the presenter uses, and
make the factory injectable — the same shape as `AppModel.makeConnection`.

Add to `App/WebAuthPresenter.swift`:

```swift
/// The two things `WebAuthPresenter` needs from a system auth session. Exists so a test can drive
/// the cancellation path: `ASWebAuthenticationSession` presents real browser UI, so the shipping
/// type can never appear in a unit test, and the continuation-resume rules below are precisely
/// what needs covering.
@MainActor
protocol WebAuthUISession: AnyObject {
    @discardableResult func start() -> Bool
    func cancel()
}

extension ASWebAuthenticationSession: WebAuthUISession {}

/// Builds one system auth session. The context provider is passed in rather than captured so the
/// default factory can stay a plain value with no reference to the presenter that owns it.
typealias WebAuthUISessionFactory = @MainActor (
    _ url: URL,
    _ callbackScheme: String,
    _ contextProvider: any ASWebAuthenticationPresentationContextProviding,
    _ completion: @escaping @Sendable (URL?, (any Error)?) -> Void
) -> any WebAuthUISession
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/HavenAppTests/WebAuthCancellationTests.swift`. The fake never completes on its own,
which is exactly the situation the production bug hangs on.

```swift
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

    /// The defect this task exists for: cancelling the awaiting task must end the await. Before the
    /// fix the continuation is never resumed and this times out rather than failing cleanly, so the
    /// race against a sleep is what turns a hang into a readable failure.
    @Test func cancellingTheAwaitingTaskEndsTheAwaitRatherThanHanging() async throws {
        let (presenter, session) = makePresenter()

        let auth = Task {
            try await presenter.authenticate(url: URL(string: "https://example.invalid/auth")!,
                                             callbackScheme: "havenapp")
        }

        // Let the nested Task create and start the session before cancelling.
        while session()?.startCount ?? 0 == 0 { await Task.yield() }

        auth.cancel()

        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await auth.result; return true }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return false }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        #expect(finished, "authenticate() did not return after its task was cancelled — it hung")
        #expect(session()?.cancelCount == 1, "the browser sheet was left open")
    }

    /// `ASWebAuthenticationSession.cancel()`'s completion behaviour is not reliably documented, so
    /// the resume-once gate has to hold when cancelling *does* fire the completion handler. Without
    /// the gate this is a double resume, which traps rather than fails.
    @Test func cancellingSurvivesASessionThatAlsoFiresItsCompletionHandler() async throws {
        let (presenter, session) = makePresenter()

        let auth = Task {
            try await presenter.authenticate(url: URL(string: "https://example.invalid/auth")!,
                                             callbackScheme: "havenapp")
        }
        while session()?.startCount ?? 0 == 0 { await Task.yield() }
        session()?.completionFiresOnCancel = true

        auth.cancel()
        _ = await auth.result   // must not trap
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `xcodebuild test -scheme HavenApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:HavenAppTests/WebAuthCancellationTests`

Expected before the fix: the file does not compile, because `WebAuthPresenter` has no
`init(makeSession:)` yet. That is a compile failure, not a test failure — it does not prove the
cancellation behaviour. **After Step 4 lands the initializer but before the cancellation handler is
added**, re-run and confirm `cancellingTheAwaitingTaskEndsTheAwaitRatherThanHanging` fails on the
`finished` expectation. Record that observed failure in the report; it is the mutation evidence the
Global Constraints require.

- [ ] **Step 4: Rewrite `authenticate` with a resume-once gate and a cancellation handler**

Replace the body of `App/WebAuthPresenter.swift`'s `authenticate`. Keep the existing
`presentationAnchor` method and the type's conformances exactly as they are.

```swift
@MainActor
final class WebAuthPresenter: NSObject, WebAuthSession, ASWebAuthenticationPresentationContextProviding {
    private let makeSession: WebAuthUISessionFactory

    init(makeSession: @escaping WebAuthUISessionFactory = { url, scheme, context, completion in
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme,
                                                 completionHandler: completion)
        session.presentationContextProvider = context
        session.prefersEphemeralWebBrowserSession = false
        return session
    }) {
        self.makeSession = makeSession
        super.init()
    }

    /// Resumes its continuation exactly once, whoever gets there first.
    ///
    /// **Both guards are load-bearing.** Without the cancellation handler, cancelling the awaiting
    /// task while the sheet is open leaves the continuation unresumed and that task hangs for the
    /// life of the process — reachable in the shipping app, because `signOut()` cancels the
    /// `connectTask` that `signIn()` awaits this through. Without the resume-once gate, a
    /// `cancel()` that *also* fires the completion handler resumes twice, which traps. The real
    /// API's behaviour on that second point is not reliably documented, so this is written to be
    /// correct either way rather than to match one reading of it.
    nonisolated func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        let state = SessionState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                Task { @MainActor in
                    // Cancellation may already have run before this Task got to execute; starting a
                    // sheet nobody is waiting for would present browser UI over a signed-out app.
                    guard !state.isCancelled else {
                        state.finish(cont, with: .failure(CancellationError()))
                        return
                    }
                    let session = self.makeSession(url, callbackScheme, self) { cb, err in
                        Task { @MainActor in
                            if let cb { state.finish(cont, with: .success(cb)) }
                            else {
                                state.finish(cont, with: .failure(
                                    err ?? WSError(code: "oauth", message: "cancelled")))
                            }
                        }
                    }
                    state.session = session
                    session.start()
                }
            }
        } onCancel: {
            Task { @MainActor in state.cancel() }
        }
    }

    /// Shared, `@MainActor`-isolated state between the continuation body and the cancellation
    /// handler: the handler needs the session (created later, inside the nested task) to close the
    /// sheet, and both paths need the same "has this resumed yet" flag.
    @MainActor
    private final class SessionState {
        var session: (any WebAuthUISession)?
        private(set) var isCancelled = false
        private var hasResumed = false

        func finish(_ cont: CheckedContinuation<URL, any Error>, with result: Result<URL, any Error>) {
            guard !hasResumed else { return }
            hasResumed = true
            cont.resume(with: result)
        }

        func cancel() {
            isCancelled = true
            session?.cancel()
            session = nil
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
```

**Note on the cancellation path's resume.** `cancel()` above closes the sheet but does not itself
resume the continuation, on the assumption the completion handler fires. If Step 3's re-run shows
the awaiting task still hangs after cancellation — i.e. the real behaviour is that `cancel()` does
*not* invoke the completion — then `SessionState.cancel()` must also resume with
`CancellationError()`. The resume-once gate makes adding that safe. **Determine which by running
the test, not by reasoning about the API**, and record what you observed.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild test -scheme HavenApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:HavenAppTests/WebAuthCancellationTests`
Expected: 3 tests, all passing.

- [ ] **Step 6: Run both full suites**

Run: `swift test --package-path Packages/HavenCore`
Expected: 788 tests passing.

Run: `xcodebuild test -scheme HavenApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: 110 tests passing (107 baseline + 3 new), TEST SUCCEEDED.

- [ ] **Step 7: Regenerate the Xcode project**

A new file was added under `Tests/`, so the generated project must be refreshed or the new test
file will not be in the target on a clean checkout.

Run: `xcodegen generate`
Then re-run the app suite once more to confirm the new tests are still collected.

- [ ] **Step 8: Commit**

```bash
git add App/WebAuthPresenter.swift Tests/HavenAppTests/WebAuthCancellationTests.swift
git commit -m "fix(app): a cancelled sign-in closes the sheet instead of hanging forever"
```
