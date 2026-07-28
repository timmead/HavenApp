import Testing
import Foundation
@testable import HavenApp

/// `Phase.isConnectionInProgress` decides whether `RootView` holds its tongue for the quiet period
/// or says something. Both mistakes are visible: a phase wrongly reported as connecting hides a
/// screen the user needs, and one wrongly reported as idle brings back the spinner flash the quiet
/// period exists to remove.
@Suite @MainActor struct PhaseTests {
    @Test func onlyTheActivelyConnectingPhasesCount() {
        // `.launching` counts: at that point the app is about to connect, and treating it as idle
        // is exactly what used to flash `LoginView` past on every launch.
        #expect(AppModel.Phase.launching.isConnectionInProgress)
        #expect(AppModel.Phase.connecting.isConnectionInProgress)
        #expect(AppModel.Phase.retrying(attempt: 1, isReconnect: false).isConnectionInProgress)
        #expect(AppModel.Phase.retrying(attempt: 4, isReconnect: true).isConnectionInProgress)

        #expect(!AppModel.Phase.loggedOut.isConnectionInProgress)
        #expect(!AppModel.Phase.ready.isConnectionInProgress)
        // An error is terminal and actionable — `LoginView` shows it with the address editable —
        // so it must never be held back by the quiet period.
        #expect(!AppModel.Phase.error("nope").isConnectionInProgress)
    }

    /// The wording, which is the half a view cannot be trusted with: "Connection lost" is only true
    /// of a session that existed. Every in-progress phase must have something to say, since being
    /// non-`nil` is what marks it in progress at all.
    @Test func eachInProgressPhaseSaysSomethingTrue() throws {
        #expect(AppModel.Phase.launching.connectionProgressMessage == "Connecting to Home Assistant…")
        #expect(AppModel.Phase.connecting.connectionProgressMessage == "Connecting to Home Assistant…")

        let firstConnect = try #require(
            AppModel.Phase.retrying(attempt: 2, isReconnect: false).connectionProgressMessage)
        #expect(!firstConnect.contains("lost"), "nothing was lost — this connection was never made")
        #expect(firstConnect.contains("2"))

        let reconnect = try #require(
            AppModel.Phase.retrying(attempt: 2, isReconnect: true).connectionProgressMessage)
        #expect(reconnect.contains("lost"))
    }

    /// **The launch flicker, at the level it actually lived.** Nothing has looked in the Keychain
    /// when the first frame renders, so a `.loggedOut` starting value was a claim the app had not
    /// earned — and `RootView` duly rendered the sign-in screen for a session that was there the
    /// whole time.
    @Test func aFreshModelHasNotYetDecidedWhetherItIsSignedOut() {
        let app = AppModel(defaults: makeTestDefaults(), tokens: FakeTokenStore())
        if case .launching = app.phase {} else {
            Issue.record("expected .launching before anything has looked for a session, got \(app.phase)")
        }
    }

    /// …and the `else` that resolves it. Without this, a launch with genuinely no session would sit
    /// on the connecting screen forever rather than offering sign-in.
    @Test func restoringWithNoSessionEndsUpSignedOut() async {
        let app = AppModel(defaults: makeTestDefaults(), tokens: FakeTokenStore())

        await app.restoreIfPossible()

        if case .loggedOut = app.phase {} else {
            Issue.record("expected .loggedOut with no saved session, got \(app.phase)")
        }
    }
}
