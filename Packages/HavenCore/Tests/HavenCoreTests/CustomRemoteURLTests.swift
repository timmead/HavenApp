import Testing
import Foundation
@testable import HavenCore

/// The second supported remote path: a URL the user types themselves, for people running Tailscale
/// or their own reverse proxy rather than Nabu Casa.
///
/// Two properties carry this whole feature, and both are asserted below rather than argued for:
/// `http://` is refused (and refused *before* anything is written), and the custom URL lives in a
/// slot of its own so it coexists with a Nabu Casa URL instead of competing with it.
@Suite struct CustomRemoteURLTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    private func freshDefaults(_ name: String) -> UserDefaults {
        let suite = "test.\(name).\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    // MARK: - HTTPS required, by rejection and not by rewriting

    @Test func anExplicitHTTPAddressIsRejectedWithAnActionableExplanation() {
        let result = CustomRemoteURL.validating("http://ha.example.com")
        guard case .failure(let error) = result else {
            Issue.record("http:// must not be accepted"); return
        }
        #expect(error == .insecureScheme)
        // Actionable, not merely correct: it has to name https, say why Haven won't substitute it,
        // and point at something the user can actually do next. "Invalid URL" would leave someone
        // whose reverse proxy is plain HTTP with nowhere to go.
        #expect(error.message.contains("https://"))
        #expect(error.message.contains("encrypted"))
        #expect(error.message.contains("Tailscale"))
    }

    @Test func aRejectedHTTPAddressIsNeverPersisted() {
        // The property that matters more than the message: a refused value must not be left behind
        // for the next connect to pick up as a candidate.
        let d = freshDefaults("httpNotPersisted")
        let store = CustomRemoteURLStore(defaults: d)

        #expect(store.save("http://ha.example.com") == .failure(.insecureScheme))

        #expect(store.url == nil)
        #expect(d.string(forKey: CustomRemoteURLStore.storageKey) == nil)
    }

    @Test func anHTTPAddressDoesNotOverwriteAnAlreadyStoredOne() {
        // The rejection must also be inert — a failed edit leaves the working address alone rather
        // than clearing it and stranding the user with no remote path at all.
        let d = freshDefaults("httpDoesNotOverwrite")
        let store = CustomRemoteURLStore(defaults: d)
        #expect(store.save("https://ha.example.com") == .success(url("https://ha.example.com")))

        #expect(store.save("http://ha.example.com") == .failure(.insecureScheme))

        #expect(store.url == url("https://ha.example.com"))
    }

    @Test func anHTTPSAddressIsAcceptedUnchanged() {
        #expect(CustomRemoteURL.validating("https://ha.example.com") == .success(url("https://ha.example.com")))
        #expect(CustomRemoteURL.validating("https://ha.example.com:8443") == .success(url("https://ha.example.com:8443")))
        // Whitespace from a paste or a keyboard's trailing space is trimmed, not treated as junk.
        #expect(CustomRemoteURL.validating("  https://ha.example.com  ") == .success(url("https://ha.example.com")))
    }

    @Test func aSchemelessAddressGetsHTTPSFilledIn() {
        // Not the "silent upgrade" that `insecureScheme` refuses: nothing was chosen here, so
        // nothing is being overridden, and https is the only scheme this field can hold. A
        // Tailscale user typing a bare hostname is the common case.
        #expect(CustomRemoteURL.validating("ha.example.com") == .success(url("https://ha.example.com")))
        // Host:port is the shape that makes the ordering of the checks load-bearing —
        // `URL(string: "ha.example.com:8123")` parses as scheme `ha.example.com` with no host at
        // all, so judging the scheme after parsing would report something baffling here.
        #expect(CustomRemoteURL.validating("ha.example.com:8123") == .success(url("https://ha.example.com:8123")))
    }

    @Test func nonsenseAndOtherSchemesAreRejectedAsMalformed() {
        #expect(CustomRemoteURL.validating("") == .failure(.empty))
        #expect(CustomRemoteURL.validating("   ") == .failure(.empty))
        // Prefixing `https://` onto these would build a URL that parses but means nothing.
        #expect(CustomRemoteURL.validating("wss://ha.example.com") == .failure(.malformed))
        #expect(CustomRemoteURL.validating("ftp://ha.example.com") == .failure(.malformed))
        #expect(CustomRemoteURL.validating("https://") == .failure(.malformed))
    }

    @Test func theStoredValueRoundTripsThroughUserDefaults() {
        let d = freshDefaults("roundTrip")
        let store = CustomRemoteURLStore(defaults: d)
        #expect(store.url == nil)
        #expect(store.save("ha.example.com") == .success(url("https://ha.example.com")))
        // Read back through a *second* store over the same defaults — i.e. the next app launch.
        #expect(CustomRemoteURLStore(defaults: d).url == url("https://ha.example.com"))
    }

    // MARK: - Its own slot: coexistence with Nabu Casa, not competition
    //
    // Task 2 flagged this exactly: `cloud/status` writes the Nabu Casa URL to the same
    // `discoveredExternalURL` key `get_config`'s `external_url` uses, and runs second, so it wins.
    // Right for those two — but a user running both Nabu Casa *and* their own reverse proxy would
    // have silently lost the reverse proxy from the candidate list if this value shared that slot.

    @Test func aCustomRemoteURLAndANabuCasaURLBothAppearWithNabuCasaFirst() {
        let candidates = ConnectionEndpoint.candidates(
            userEntered: url("http://192.168.1.42:8123"),
            discoveredInternal: nil,
            discoveredExternal: url("https://abc123.ui.nabu.casa"),
            customRemote: url("https://ha.example.com")
        )
        #expect(candidates == [
            .local(url("http://192.168.1.42:8123")),
            // Nabu Casa first among the remotes: it is the managed tunnel, verified by the cloud
            // account itself. The custom URL follows — and, crucially, is still there.
            .remote(url("https://abc123.ui.nabu.casa")),
            .remote(url("https://ha.example.com")),
        ])
    }

    @Test func theCustomRemoteURLIsClassifiedRemoteEvenWithNoOtherRemoteKnown() {
        let candidates = ConnectionEndpoint.candidates(
            userEntered: url("http://192.168.1.42:8123"),
            discoveredInternal: nil,
            discoveredExternal: nil,
            customRemote: url("https://ha.example.com")
        )
        #expect(candidates == [
            .local(url("http://192.168.1.42:8123")),
            .remote(url("https://ha.example.com")),
        ])
    }

    @Test func nabuCasaStaysAheadOfTheCustomURLWhenRemoteLeads() {
        // The relative order of the two remotes must survive `ConnectionPreference`'s remote-leading
        // re-partition (known-not-home, or cellular), which is where an unstable partition would
        // show up. Asserted rather than assumed.
        let candidates = ConnectionPreference.candidates(
            userEntered: url("http://192.168.1.42:8123"),
            discoveredInternal: nil,
            discoveredExternal: url("https://abc123.ui.nabu.casa"),
            customRemote: url("https://ha.example.com"),
            homeSSIDMatch: false,
            pathClass: .wifi
        )
        #expect(candidates == [
            .remote(url("https://abc123.ui.nabu.casa")),
            .remote(url("https://ha.example.com")),
            .local(url("http://192.168.1.42:8123")),
        ])
    }

    @Test func aCustomRemoteURLSurvivesACloudStatusResultThatSetsTheNabuCasaSlot() {
        // The regression Task 2 named, run through the real write paths on one shared defaults
        // store: the custom URL is saved, then `cloud/status` comes back with a Nabu Casa domain
        // and its adopted URL is written to the discovered-external slot exactly as
        // `AppModel.rememberNabuCasaRemoteAccess` writes it. Both must still be dialled afterwards.
        let d = freshDefaults("cloudStatusDoesNotClobber")
        let store = CustomRemoteURLStore(defaults: d)
        #expect(store.save("https://ha.example.com") == .success(url("https://ha.example.com")))

        let status = HACloudStatus(
            loggedIn: true,
            activeSubscription: true,
            remoteDomain: "abc123.ui.nabu.casa",
            remoteConnected: true,
            prefs: HACloudStatus.Prefs(remoteEnabled: true)
        )
        let outcome = NabuCasaRemoteAccessDetector.classify(.success(status))
        let adopted = NabuCasaRemoteAccessDetector.adoptableRemoteURL(from: outcome, learnedOver: .local)
        #expect(adopted == url("https://abc123.ui.nabu.casa"))
        d.set(adopted!.absoluteString, forKey: DiscoveredURLMigration.discoveredExternalURLKey)

        // The typed URL is untouched…
        #expect(store.url == url("https://ha.example.com"))
        // …and both are candidates, in the documented order.
        let candidates = ConnectionEndpoint.candidates(
            userEntered: url("http://192.168.1.42:8123"),
            discoveredInternal: nil,
            discoveredExternal: d.string(forKey: DiscoveredURLMigration.discoveredExternalURLKey).flatMap(URL.init(string:)),
            customRemote: store.url
        )
        #expect(candidates == [
            .local(url("http://192.168.1.42:8123")),
            .remote(url("https://abc123.ui.nabu.casa")),
            .remote(url("https://ha.example.com")),
        ])
    }

    @Test func clearingTheCustomURLRemovesOnlyIt() {
        let d = freshDefaults("clearRemovesOnlyIt")
        let store = CustomRemoteURLStore(defaults: d)
        store.save("https://ha.example.com")
        d.set("https://abc123.ui.nabu.casa", forKey: DiscoveredURLMigration.discoveredExternalURLKey)
        d.set("http://192.168.1.42:8123", forKey: DiscoveredURLMigration.discoveredInternalURLKey)
        d.set("http://192.168.1.42:8123", forKey: DiscoveredURLMigration.lastWorkingURLKey)

        store.clear()

        #expect(store.url == nil)
        #expect(d.string(forKey: DiscoveredURLMigration.discoveredExternalURLKey) == "https://abc123.ui.nabu.casa")
        #expect(d.string(forKey: DiscoveredURLMigration.discoveredInternalURLKey) == "http://192.168.1.42:8123")
        #expect(d.string(forKey: DiscoveredURLMigration.lastWorkingURLKey) == "http://192.168.1.42:8123")
    }

    @Test func theOvernightMigrationDoesNotSweepUpTheCustomURL() {
        // `DiscoveredURLMigration` clears values written under rules that no longer exist. This one
        // was written by the user, under no rule at all — a device upgrading must not lose it.
        let d = freshDefaults("migrationLeavesCustomAlone")
        let store = CustomRemoteURLStore(defaults: d)
        store.save("https://ha.example.com")

        #expect(DiscoveredURLMigration.runIfNeeded(in: d))

        #expect(store.url == url("https://ha.example.com"))
    }
}
