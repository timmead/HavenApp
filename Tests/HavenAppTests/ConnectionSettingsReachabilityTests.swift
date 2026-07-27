import Testing
import Foundation
@testable import HavenApp

/// **Regression: connection settings were unreachable exactly when they mattered.**
///
/// `ConnectionSettingsView` used to be presented only from `DashboardView`'s overflow menu, and
/// `RootView` renders `DashboardView` only when `phase == .ready`. So the screen holding the custom
/// remote URL field — the one thing that fixes a self-hosted user stranded away from home — was
/// reachable only from a connected app. The user it exists for could never get to it.
///
/// These tests render the real `RootView` in a real window and search the resulting tree, rather
/// than asking a predicate whether it thinks the button is there. That distinction is the whole
/// point: a `var connectionSettingsIsReachable: Bool` on a routing enum would be a second copy of
/// the claim that a `RootView` edit could silently contradict, which is precisely how a security fix
/// once shipped with 107 green tests over a helper while the real decision went unexercised.
@Suite @MainActor struct ConnectionSettingsReachabilityTests {
    private static let button = "Connection settings"

    private func labels(for phase: AppModel.Phase, _ name: String = #function) -> Set<String> {
        let model = AppModel(defaults: makeTestDefaults(name), tokens: FakeTokenStore())
        model.phase = phase
        return ViewProbe.labels(in: RootViewHarness(model: model))
    }

    /// The cold-launch screen. A user who has never connected, or who signed out, must be able to
    /// set a remote address before their first successful connection — otherwise the feature is
    /// only available to people who don't need it yet.
    @Test func reachableWhenLoggedOut() {
        let labels = labels(for: .loggedOut)
        // Proves the probe rendered the login screen and not something else — without this the
        // assertion below could pass over an empty or wrong tree.
        #expect(labels.contains("Sign in"))
        #expect(labels.contains(Self.button))
    }

    /// Where a terminal failure lands — an ATS-blocked token refresh, a malformed address. The user
    /// is looking at an error and the fix for several of those errors is behind this button.
    @Test func reachableInTheErrorPhase() {
        let labels = labels(for: .error("every candidate this round was refused"))
        #expect(labels.contains("Sign in"))
        #expect(labels.contains(Self.button))
    }

    /// **The defect's own scenario.** Retrying is unbounded, so without this the stranded
    /// self-hosted user sits here indefinitely with no route to the setting that would fix it. The
    /// only other way out is "Change server", which signs out and discards the session.
    @Test func reachableWhileRetrying() {
        let labels = labels(for: .retrying(attempt: 3))
        #expect(labels.contains("Change server"), "the retry screen should be what got rendered")
        #expect(labels.contains(Self.button))
    }

    /// A negative control for the probe itself. If `ViewProbe` matched loosely — or returned the
    /// same labels regardless of what it was handed — every assertion above would be worthless.
    @Test func theProbeDistinguishesScreens() {
        let loggedOut = labels(for: .loggedOut)
        let retrying = labels(for: .retrying(attempt: 1))
        #expect(loggedOut.contains("Sign in"))
        #expect(!retrying.contains("Sign in"))
        #expect(!loggedOut.contains("Change server"))
    }
}
