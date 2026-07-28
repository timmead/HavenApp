import Testing
import Foundation
@testable import HavenApp

/// `Phase.isConnectionInProgress` decides whether `RootView` holds its tongue for the quiet period
/// or says something. Both mistakes are visible: a phase wrongly reported as connecting hides a
/// screen the user needs, and one wrongly reported as idle brings back the spinner flash the quiet
/// period exists to remove.
@Suite @MainActor struct PhaseTests {
    @Test func onlyTheActivelyConnectingPhasesCount() {
        #expect(AppModel.Phase.connecting.isConnectionInProgress)
        #expect(AppModel.Phase.retrying(attempt: 1, isReconnect: false).isConnectionInProgress)
        #expect(AppModel.Phase.retrying(attempt: 4, isReconnect: true).isConnectionInProgress)

        #expect(!AppModel.Phase.loggedOut.isConnectionInProgress)
        #expect(!AppModel.Phase.ready.isConnectionInProgress)
        // An error is terminal and actionable — `LoginView` shows it with the address editable —
        // so it must never be held back by the quiet period.
        #expect(!AppModel.Phase.error("nope").isConnectionInProgress)
    }
}
