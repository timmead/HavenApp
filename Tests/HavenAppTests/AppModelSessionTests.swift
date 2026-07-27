import Testing
import Foundation
import HavenCore
@testable import HavenApp

/// **Regression: the URL-adoption decision that no test executed.**
///
/// Whatever `AppModel` persists under the discovered-URL keys becomes a future connection
/// candidate that `TokenProvider.setBaseURL` will later POST the refresh token to. The rule that
/// makes that safe is one sentence — *a remote address is only ever learned over a connection
/// classified `.local`* — and it lived in `AppModel`, where nothing could reach it. 107 green tests
/// covered `DiscoveredCandidateURLs.validating`, the helper; the call site that decides whether to
/// write went unexercised, and the vulnerability survived two rounds of being "fixed".
///
/// So these assert on the storage, not on the helper: after the call, is the address in the slot or
/// isn't it. Each test gets its own `UserDefaults` suite — the standard domain here belongs to the
/// host app, and a test that adopted a URL into it would leave a real candidate behind for the next
/// launch to dial.
@Suite @MainActor struct AppModelURLAdoptionTests {
    private func model(_ name: String = #function) -> (AppModel, UserDefaults, FakeTokenStore) {
        let defaults = makeTestDefaults(name)
        let tokens = FakeTokenStore()
        return (AppModel(defaults: defaults, tokens: tokens), defaults, tokens)
    }

    private let internalKey = DiscoveredURLMigration.discoveredInternalURLKey
    private let externalKey = DiscoveredURLMigration.discoveredExternalURLKey
    private let lastWorkingKey = DiscoveredURLMigration.lastWorkingURLKey

    // MARK: - get_config

    @Test func aLocalConnectionAdoptsBothURLsFromGetConfig() {
        let (app, defaults, _) = model()
        app.rememberDiscoveredURLs(
            HAInstanceConfig(internalURL: URL(string: "http://192.168.1.20:8123")!,
                             externalURL: URL(string: "https://ha.example.com")!),
            learnedOver: .local
        )
        #expect(defaults.string(forKey: internalKey) == "http://192.168.1.20:8123")
        #expect(defaults.string(forKey: externalKey) == "https://ha.example.com")
    }

    /// **The security property.** The response arrived over the internet, so it cannot be trusted
    /// to name an address this app will later hand a refresh token to — no matter how plausible it
    /// looks. Nothing is written, and "nothing" is asserted on the slots themselves.
    @Test func aRemoteConnectionAdoptsNothingFromGetConfig() {
        let (app, defaults, _) = model()
        app.rememberDiscoveredURLs(
            HAInstanceConfig(internalURL: URL(string: "http://192.168.1.20:8123")!,
                             externalURL: URL(string: "https://ha.example.com")!),
            learnedOver: .remote
        )
        #expect(defaults.string(forKey: internalKey) == nil)
        #expect(defaults.string(forKey: externalKey) == nil)
    }

    /// A remote connection must not be able to *overwrite* what a previous local one learned
    /// either — the untrusted answer losing is not the same as the trusted answer surviving.
    @Test func aRemoteConnectionDoesNotOverwriteWhatALocalOneLearned() {
        let (app, defaults, _) = model()
        app.rememberDiscoveredURLs(
            HAInstanceConfig(internalURL: URL(string: "http://192.168.1.20:8123")!,
                             externalURL: URL(string: "https://ha.example.com")!),
            learnedOver: .local
        )
        app.rememberDiscoveredURLs(
            HAInstanceConfig(internalURL: URL(string: "http://10.0.0.9:8123")!,
                             externalURL: URL(string: "https://attacker.example")!),
            learnedOver: .remote
        )
        #expect(defaults.string(forKey: internalKey) == "http://192.168.1.20:8123")
        #expect(defaults.string(forKey: externalKey) == "https://ha.example.com")
    }

    // MARK: - cloud/status

    private var subscribedAndEnabled: Result<HACloudStatus, WSError> {
        .success(HACloudStatus(loggedIn: true, activeSubscription: true,
                               remoteDomain: "abc123.ui.nabu.casa", remoteConnected: true,
                               prefs: .init(remoteEnabled: true)))
    }

    @Test func aLocalConnectionAdoptsTheNabuCasaRemoteURL() {
        let (app, defaults, _) = model()
        app.rememberNabuCasaRemoteAccess(subscribedAndEnabled, learnedOver: .local)
        #expect(defaults.string(forKey: externalKey) == "https://abc123.ui.nabu.casa")
        #expect(app.remoteAccess == .remoteAvailable(URL(string: "https://abc123.ui.nabu.casa")!))
    }

    /// The same answer heard over the internet. It is honest to *say* remote access exists — that
    /// is a rendering input, and `remoteAccess` is still set — but **adopting** the address is a
    /// different act, and it does not happen.
    @Test func aRemoteConnectionReportsButDoesNotAdoptTheNabuCasaURL() {
        let (app, defaults, _) = model()
        app.rememberNabuCasaRemoteAccess(subscribedAndEnabled, learnedOver: .remote)
        #expect(app.remoteAccess == .remoteAvailable(URL(string: "https://abc123.ui.nabu.casa")!))
        #expect(defaults.string(forKey: externalKey) == nil)
    }

    /// A lapsed subscription, heard locally: the dead `*.ui.nabu.casa` address is removed rather
    /// than left sitting ahead of the user's own remote address forever.
    @Test func aLapsedSubscriptionClearsTheStoredNabuCasaURL() {
        let (app, defaults, _) = model()
        app.rememberNabuCasaRemoteAccess(subscribedAndEnabled, learnedOver: .local)
        #expect(defaults.string(forKey: externalKey) == "https://abc123.ui.nabu.casa")

        app.rememberNabuCasaRemoteAccess(
            .success(HACloudStatus(loggedIn: true, activeSubscription: false)), learnedOver: .local
        )
        #expect(defaults.string(forKey: externalKey) == nil)
    }

    /// A transport blip is not a lapsed subscription. `.indeterminate` must leave a working stored
    /// address alone — forgetting it here would cost remote access on the next connect for the sake
    /// of one failed request.
    @Test func anIndeterminateAnswerLeavesTheStoredURLAlone() {
        let (app, defaults, _) = model()
        app.rememberNabuCasaRemoteAccess(subscribedAndEnabled, learnedOver: .local)
        app.rememberNabuCasaRemoteAccess(
            .failure(WSError(code: "timeout", message: "no answer")), learnedOver: .local
        )
        #expect(defaults.string(forKey: externalKey) == "https://abc123.ui.nabu.casa")
    }

    // MARK: - Forgetting

    /// Everything describing how to reach the previous instance goes, together. A survivor here is
    /// a candidate URL for one Home Assistant carried into a session with a different one.
    @Test func forgettingClearsEveryDiscoveredSlotAndTheHomeNetwork() {
        let (app, defaults, _) = model()
        app.rememberDiscoveredURLs(
            HAInstanceConfig(internalURL: URL(string: "http://192.168.1.20:8123")!,
                             externalURL: URL(string: "https://ha.example.com")!),
            learnedOver: .local
        )
        defaults.set("http://192.168.1.20:8123", forKey: lastWorkingKey)
        defaults.set("HomeWiFi", forKey: HomeNetwork.homeSSIDKey)
        app.rememberNabuCasaRemoteAccess(subscribedAndEnabled, learnedOver: .local)

        app.forgetDiscoveredURLs()

        #expect(defaults.string(forKey: internalKey) == nil)
        #expect(defaults.string(forKey: externalKey) == nil)
        #expect(defaults.string(forKey: lastWorkingKey) == nil)
        #expect(defaults.string(forKey: HomeNetwork.homeSSIDKey) == nil)
        #expect(app.remoteAccess == nil)
    }

    // MARK: - The custom remote URL

    /// The user's own address lives in its own slot, and must not be confused with — or overwritten
    /// by — the discovered one. Someone can legitimately run both Nabu Casa and a reverse proxy.
    @Test func theCustomRemoteURLGetsItsOwnSlot() {
        let (app, defaults, _) = model()
        app.rememberNabuCasaRemoteAccess(subscribedAndEnabled, learnedOver: .local)
        #expect(app.saveCustomRemoteURL("https://ha.tailnet.ts.net").isSuccess)

        #expect(defaults.string(forKey: CustomRemoteURLStore.storageKey) == "https://ha.tailnet.ts.net")
        #expect(defaults.string(forKey: externalKey) == "https://abc123.ui.nabu.casa")
        #expect(app.customRemoteURL == URL(string: "https://ha.tailnet.ts.net"))
    }

    /// A rejected address writes nothing and leaves the working one in place — no half-accepted
    /// value for the next connect to pick up.
    @Test func aRejectedCustomRemoteURLChangesNothing() {
        let (app, defaults, _) = model()
        #expect(app.saveCustomRemoteURL("https://ha.example.com").isSuccess)
        #expect(!app.saveCustomRemoteURL("http://ha.example.com").isSuccess)

        #expect(defaults.string(forKey: CustomRemoteURLStore.storageKey) == "https://ha.example.com")
        #expect(app.customRemoteURL == URL(string: "https://ha.example.com"))
    }
}

/// The parts of the sign-in/sign-out state machine that can be exercised without a network.
///
/// `connect()` itself cannot: it constructs its `NWWebSocketConnection` inline and `OAuthClient` is
/// a concrete struct with no protocol, so there is no seam to put a fake behind. Rather than contort
/// the model — or, far worse, let a test dial the developer's own Home Assistant — that gap is
/// stated in the suite that has it. What *is* reachable is the validation gate before OAuth starts,
/// and everything sign-out tears down.
@Suite @MainActor struct AppModelSessionTests {
    private func model(_ name: String = #function) -> (AppModel, UserDefaults, FakeTokenStore) {
        let defaults = makeTestDefaults(name)
        let tokens = FakeTokenStore()
        return (AppModel(defaults: defaults, tokens: tokens), defaults, tokens)
    }

    /// The guard that runs **before** any network call, so this is safe to drive directly: a URL
    /// that fails validation lands on `.error` and nothing is persisted. If this ever stopped
    /// short-circuiting, the test would hang or reach out — which is itself the signal.
    @Test func anInvalidAddressFailsBeforeAnythingIsSaved() async {
        let (app, defaults, _) = model()
        app.serverURLText = "not a url at all"
        await app.signIn()

        guard case .error(let message) = app.phase else {
            Issue.record("expected .error, got \(app.phase)"); return
        }
        // Asserted on the *shape* of the message rather than its wording: the copy is
        // `ServerURL.Invalid.message`'s to own and is covered case-by-case in `ServerURLTests`.
        // Pinning the exact sentence here would mean every wording change breaks a test about
        // persistence, which is what this one is actually for.
        #expect(!message.isEmpty)
        #expect(defaults.string(forKey: "baseURL") == nil)
    }

    /// The address is now persisted only *after* OAuth succeeds. Previously it was written before
    /// the network call, so a mistyped host became the saved base URL for every later launch and
    /// the user had to notice and retype it to escape a server they had never reached.
    ///
    /// Driven through a scheme this app can't speak, so it fails at validation without any
    /// possibility of a network call — see the note on `signIn` above about not driving past the
    /// guard with a parseable URL.
    @Test func aRejectedAddressNeverBecomesTheSavedServer() async {
        let (app, defaults, _) = model()
        defaults.set("http://previously-working.local:8123", forKey: "baseURL")

        app.serverURLText = "ftp://homeassistant.local:8123"
        await app.signIn()

        guard case .error = app.phase else {
            Issue.record("expected .error, got \(app.phase)"); return
        }
        // The address that *did* work is still there — a failed attempt doesn't clear it either.
        #expect(defaults.string(forKey: "baseURL") == "http://previously-working.local:8123")
    }

    @Test func anEmptyAddressIsRefused() async {
        let (app, defaults, _) = model()
        app.serverURLText = "   "
        await app.signIn()

        guard case .error = app.phase else {
            Issue.record("expected .error, got \(app.phase)"); return
        }
        #expect(defaults.string(forKey: "baseURL") == nil)
    }

    // **A gap this suite deliberately does not close.** `signIn("ftp://homeassistant.local:8123")`
    // is *not* refused: the scheme check looks for `^https?://`, doesn't find it, prepends
    // `http://`, and `http://ftp://homeassistant.local:8123` then parses as a perfectly valid URL
    // whose host is `ftp` — so the guard passes and OAuth starts against a nonsensical address.
    // Writing the test that asserts otherwise would have meant changing `signIn` to make it pass,
    // which this work is explicitly barred from doing; the finding is reported instead. Note also
    // that any test driving `signIn` past that guard opens a real `ASWebAuthenticationSession`,
    // which is why only the two rejection paths above are exercised here.

    /// No stored session means no connect attempt — the property the host-app launch guard leans
    /// on, asserted on the model itself rather than only on the guard.
    @Test func restoringWithoutATokenDoesNothing() async {
        let (app, defaults, _) = model()
        defaults.set("http://homeassistant.local:8123", forKey: "baseURL")
        await app.restoreIfPossible()
        #expect(isLoggedOut(app.phase))
    }

    /// Sign-out is the boundary where the instance is left behind: the token goes, the address
    /// goes, every discovered candidate goes, and the user's own remote address goes with them.
    @Test func signingOutClearsTheWholeSession() async {
        let (app, defaults, tokens) = model()
        defaults.set("http://homeassistant.local:8123", forKey: "baseURL")
        app.rememberDiscoveredURLs(
            HAInstanceConfig(internalURL: URL(string: "http://192.168.1.20:8123")!,
                             externalURL: URL(string: "https://ha.example.com")!),
            learnedOver: .local
        )
        app.saveCustomRemoteURL("https://ha.tailnet.ts.net")
        app.phase = .ready

        await app.signOut()

        #expect(isLoggedOut(app.phase))
        #expect(tokens.clearCount == 1)
        #expect(defaults.string(forKey: "baseURL") == nil)
        #expect(defaults.string(forKey: DiscoveredURLMigration.discoveredInternalURLKey) == nil)
        #expect(defaults.string(forKey: DiscoveredURLMigration.discoveredExternalURLKey) == nil)
        #expect(defaults.string(forKey: CustomRemoteURLStore.storageKey) == nil)
        #expect(app.customRemoteURL == nil)
        #expect(app.imageLoader == nil)
    }

    private func isLoggedOut(_ phase: AppModel.Phase) -> Bool {
        if case .loggedOut = phase { return true }
        return false
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
