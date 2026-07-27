import Testing
@testable import HavenApp

/// Proves the harness itself: that this bundle is built, loaded into the host app, and its tests
/// actually executed. Without it, "TEST SUCCEEDED" over a target that ran nothing is
/// indistinguishable from a passing suite — the exact silent-green failure this target exists to
/// end, so the first thing asserted is that the target is running at all.
///
/// Verified by inverting it once: a `#expect(Bool(false))` here fails the `xcodebuild test`
/// invocation with a non-zero exit and names the test. It is not left in.
@Suite struct HarnessTests {
    @Test func theSuiteRuns() {
        #expect(1 + 1 == 2)
    }

    /// The launch guard in `HavenAppApp`, asserted rather than assumed.
    ///
    /// A hosted unit-test bundle starts the real app before it loads the tests. The very first run
    /// of this target restored the developer's saved session and opened a WebSocket to their actual
    /// Home Assistant — `WS auth_ok` in the log — because `restoreIfPossible()` found a token in the
    /// simulator's Keychain. Nothing in this suite may touch a real home, so the condition the guard
    /// keys on is checked here: if `XCTestConfigurationFilePath` ever stops being set, this fails
    /// loudly instead of the suite quietly going back to dialling the user's house.
    @Test func theHostAppKnowsItIsUnderTest() {
        #expect(HavenAppApp.isRunningTests)
    }
}
