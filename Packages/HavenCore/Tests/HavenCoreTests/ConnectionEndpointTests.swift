import Testing
import Foundation
@testable import HavenCore

@Suite struct ConnectionEndpointTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: - isNabuCasaHost — a CLASSIFICATION predicate, not a trust check
    //
    // It answers one question: is this host *a* Nabu Casa host — which makes it remote, which
    // makes `https` mandatory. It says nothing about *whose* instance it is, and nothing here
    // should ever be read as though it did; using it as a trust gate was the C-1 incident. What
    // decides adoption is the connection class a URL was learned over — see the next section.

    @Test func isNabuCasaHostMatchesAGenuineNabuCasaHost() {
        #expect(ConnectionEndpoint.isNabuCasaHost(url("https://abc123.ui.nabu.casa")))
    }

    @Test func isNabuCasaHostRejectsAnArbitraryHTTPSHost() {
        #expect(!ConnectionEndpoint.isNabuCasaHost(url("https://evil.example")))
    }

    @Test func isNabuCasaHostRejectsLookalikeHosts() {
        // Dash instead of dot right before "ui" — not a subdomain of ui.nabu.casa at all.
        #expect(!ConnectionEndpoint.isNabuCasaHost(url("https://evil-ui.nabu.casa")))
        // A host the attacker fully controls, merely containing the string as a path component —
        // `URL.host` is only ever the authority's host, never the path, so this must not match.
        #expect(!ConnectionEndpoint.isNabuCasaHost(url("https://attacker.com/.ui.nabu.casa")))
        // A real Nabu Casa subdomain used as a subdomain of an attacker's own host.
        #expect(!ConnectionEndpoint.isNabuCasaHost(url("https://abc123.ui.nabu.casa.attacker.com")))
    }

    @Test func isNabuCasaHostAnswersIdenticallyForAPersistedValue() {
        // Round-tripping through storage changes nothing — it's a pure string predicate. Kept
        // because the predicate's *result* is easy to over-read: the host below genuinely is a
        // Nabu Casa instance, and that is true whether it's the user's own or an attacker's. That
        // gap is why adoption is decided by connection class, not by this.
        let roundTripped = UserDefaults.standard
        roundTripped.set("https://abc123.ui.nabu.casa", forKey: "test.legacyDiscoveredExternalURL")
        defer { roundTripped.removeObject(forKey: "test.legacyDiscoveredExternalURL") }
        let loaded = roundTripped.string(forKey: "test.legacyDiscoveredExternalURL").flatMap(URL.init(string:))
        #expect(loaded != nil)
        #expect(ConnectionEndpoint.isNabuCasaHost(loaded!))
    }

    // MARK: - DiscoveredCandidateURLs.validating — adoption is decided by CONNECTION CLASS
    //
    // The whole security design, in one sentence: a URL from `get_config` is adopted only when it
    // was learned over a `.local` connection, never over a `.remote` one. Discovery flows inward
    // only — the trusted local network can teach us a remote address; the untrusted internet can
    // never teach us anything.
    //
    // This replaces the URL-*shape* validation earlier rounds attempted, and is strictly stronger,
    // because it never has to answer "whose Nabu Casa account is this hostname?" — a question with
    // no answer, and the cause of the C-1 incident
    // (`docs/superpowers/2026-07-26-overnight-run-report.md` §1, now superseded). The trade is
    // deliberate and settled: LAN man-in-the-middle is accepted as out of scope, per
    // `docs/superpowers/specs/2026-07-26-havenapp-connection-model-design.md` §1. See
    // `hostileLookingHostLearnedLocallyIsAdopted` below, which asserts that trade on purpose.
    //
    // These tests exercise the exact function `AppModel.rememberDiscoveredURLs` calls; `AppModel`
    // holds no adoption logic of its own, because `App/` has no test target and anything living
    // only there is an unverified claim.

    @Test func externalURLLearnedLocallyIsAdoptedAndForcedToHTTPS() {
        let result = DiscoveredCandidateURLs.validating(
            rawInternalURL: nil,
            rawExternalURL: url("http://abc123.ui.nabu.casa"),
            learnedOver: .local
        )
        // Adopted — and a remote address is HTTPS-only, always, whatever the instance reported.
        #expect(result.externalURL == url("https://abc123.ui.nabu.casa"))
    }

    @Test func externalURLAlreadyHTTPSIsAdoptedUnchanged() {
        let result = DiscoveredCandidateURLs.validating(
            rawInternalURL: nil,
            rawExternalURL: url("https://myinstance.duckdns.org:8123"),
            learnedOver: .local
        )
        #expect(result.externalURL == url("https://myinstance.duckdns.org:8123"))
    }

    @Test func theSameExternalURLLearnedRemotelyIsNotAdopted() {
        // Identical input to `externalURLLearnedLocallyIsAdoptedAndForcedToHTTPS` — only the
        // connection class differs, and that alone is what rejects it. This is the security
        // property: a remote connection can never teach us a new address to reach the instance at,
        // and therefore never a new host to hand the refresh token to.
        let result = DiscoveredCandidateURLs.validating(
            rawInternalURL: nil,
            rawExternalURL: url("http://abc123.ui.nabu.casa"),
            learnedOver: .remote
        )
        #expect(result.externalURL == nil)
        let alreadyHTTPS = DiscoveredCandidateURLs.validating(
            rawInternalURL: nil,
            rawExternalURL: url("https://abc123.ui.nabu.casa"),
            learnedOver: .remote
        )
        #expect(alreadyHTTPS.externalURL == nil)
    }

    @Test func internalURLLearnedLocallyIsAdoptedAsIsIncludingCleartext() {
        // Cleartext HTTP on the local network is a first-class configuration, not a degraded one
        // (design §1) — `internal_url` must not be "upgraded" to https, which would simply break
        // a default Home Assistant install.
        let result = DiscoveredCandidateURLs.validating(
            rawInternalURL: url("http://192.168.1.42:8123"),
            rawExternalURL: nil,
            learnedOver: .local
        )
        #expect(result.internalURL == url("http://192.168.1.42:8123"))
    }

    @Test func theSameInternalURLLearnedRemotelyIsNotAdopted() {
        let result = DiscoveredCandidateURLs.validating(
            rawInternalURL: url("http://192.168.1.42:8123"),
            rawExternalURL: nil,
            learnedOver: .remote
        )
        #expect(result.internalURL == nil)
    }

    @Test func bothURLsAreAdoptedTogetherLocallyAndNeitherRemotely() {
        let local = DiscoveredCandidateURLs.validating(
            rawInternalURL: url("http://192.168.1.42:8123"),
            rawExternalURL: url("https://abc123.ui.nabu.casa"),
            learnedOver: .local
        )
        #expect(local == DiscoveredCandidateURLs(
            internalURL: url("http://192.168.1.42:8123"),
            externalURL: url("https://abc123.ui.nabu.casa")
        ))
        let remote = DiscoveredCandidateURLs.validating(
            rawInternalURL: url("http://192.168.1.42:8123"),
            rawExternalURL: url("https://abc123.ui.nabu.casa"),
            learnedOver: .remote
        )
        #expect(remote == DiscoveredCandidateURLs(internalURL: nil, externalURL: nil))
    }

    @Test func hostileLookingHostLearnedLocallyIsAdopted() {
        // DELIBERATE, AND NOT A BUG — do not "fix" this.
        //
        // `https://evil.example` as `external_url` is exactly the value an on-LAN attacker would
        // inject by MITM'ing the cleartext `get_config` response. It IS adopted, because it was
        // learned over a local connection, and HavenApp's trust boundary is the network edge: the
        // local network is trusted, so a URL learned there is genuine by definition
        // (design §1 — LAN man-in-the-middle is explicitly out of scope, decided by the user after
        // the C-1 incident). Rejecting it would require deciding whether a hostname "looks
        // legitimate", which is the exact reasoning that failed twice and which the
        // connection-class rule exists to eliminate.
        //
        // The property that actually protects the refresh token is the *other* half, asserted in
        // `theSameExternalURLLearnedRemotelyIsNotAdopted`: an attacker positioned on the internet
        // rather than on the LAN can never inject anything at all.
        let result = DiscoveredCandidateURLs.validating(
            rawInternalURL: url("https://evil.example"),
            rawExternalURL: url("https://evil.example"),
            learnedOver: .local
        )
        #expect(result.internalURL == url("https://evil.example"))
        #expect(result.externalURL == url("https://evil.example"))
    }

    @Test func malformedURLsAreDroppedEvenWhenLearnedLocally() {
        // Well-formedness, not trust. `URL(string: "homeassistant.local:8123")` parses with scheme
        // `homeassistant.local` and *no* host; forcing https on that yields nonsense. Nothing here
        // inspects what the host is — that would be the shape validation this rule replaced.
        let schemeless = DiscoveredCandidateURLs.validating(
            rawInternalURL: url("homeassistant.local:8123"),
            rawExternalURL: url("homeassistant.local:8123"),
            learnedOver: .local
        )
        #expect(schemeless.internalURL == nil)
        #expect(schemeless.externalURL == nil)
        let wrongScheme = DiscoveredCandidateURLs.validating(
            rawInternalURL: nil,
            rawExternalURL: url("ftp://files.example"),
            learnedOver: .local
        )
        #expect(wrongScheme.externalURL == nil)
    }

    @Test func validatingWithNoInputsYieldsNothingOverEitherConnectionClass() {
        for learnedOver in [ConnectionClass.local, .remote] {
            let result = DiscoveredCandidateURLs.validating(
                rawInternalURL: nil,
                rawExternalURL: nil,
                learnedOver: learnedOver
            )
            #expect(result == DiscoveredCandidateURLs(internalURL: nil, externalURL: nil))
        }
    }

    // DELETED: `connectionClassMirrorsTheEndpointCase`. It asserted
    // `ConnectionEndpoint.connectionClass == isRemote ? .remote : .local`, the hostname-derived
    // guess that `AppModel` passed as `learnedOver`. That property is now **removed**, not
    // deprecated: because `isRemote` is true only for `*.ui.nabu.casa`, a user-entered Tailscale or
    // reverse-proxy URL classified `.local` and `get_config`'s URLs would have been adopted over a
    // connection that crossed the internet. Keeping the test would mean keeping the property.
    // What replaces it: `ObservedConnectionClassTests`, over the address read off the live socket.

    @Test func aLocallyLearnedExternalURLBecomesARemoteCandidate() {
        // End to end through both pure functions, the way `AppModel` composes them: learned
        // locally → adopted → ordered after the local candidate → classified remote.
        let validated = DiscoveredCandidateURLs.validating(
            rawInternalURL: nil,
            rawExternalURL: url("https://abc123.ui.nabu.casa"),
            learnedOver: .local
        )
        let candidates = ConnectionEndpoint.candidates(
            userEntered: url("http://192.168.1.42:8123"),
            discoveredInternal: validated.internalURL,
            discoveredExternal: validated.externalURL
        )
        #expect(candidates == [
            .local(url("http://192.168.1.42:8123")),
            .remote(url("https://abc123.ui.nabu.casa")),
        ])
    }

    @Test func nothingLearnedRemotelyEverReachesTheCandidateList() {
        let validated = DiscoveredCandidateURLs.validating(
            rawInternalURL: url("http://10.0.0.9:8123"),
            rawExternalURL: url("https://evil.example"),
            learnedOver: .remote
        )
        let candidates = ConnectionEndpoint.candidates(
            userEntered: url("http://192.168.1.42:8123"),
            discoveredInternal: validated.internalURL,
            discoveredExternal: validated.externalURL
        )
        #expect(candidates == [.local(url("http://192.168.1.42:8123"))])
    }

    // MARK: - DiscoveredURLMigration — the silent-failure trap
    //
    // Its predecessor, `AppModel.purgeDiscoveredURLs()`, ran at the top of every iteration of
    // `connect()`'s `while true` loop. With adoption re-enabled that deletes the URL learned at
    // the end of one round before the next round reads it: "remote access never works", no error
    // anywhere, all tests green. So: exactly once per device, and a value written afterwards must
    // survive. The second half of `migrationRunsExactlyOnce` is the test that proves the trap is
    // actually gone.

    private func freshDefaults(_ name: String) -> UserDefaults {
        let suite = "test.\(name).\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func migrationClearsOvernightEraValues() {
        let d = freshDefaults("migrationClears")
        d.set("http://10.0.0.9:8123", forKey: DiscoveredURLMigration.discoveredInternalURLKey)
        d.set("https://attacker.ui.nabu.casa", forKey: DiscoveredURLMigration.discoveredExternalURLKey)
        d.set("https://attacker.ui.nabu.casa", forKey: DiscoveredURLMigration.lastWorkingURLKey)

        #expect(DiscoveredURLMigration.runIfNeeded(in: d))

        #expect(d.string(forKey: DiscoveredURLMigration.discoveredInternalURLKey) == nil)
        #expect(d.string(forKey: DiscoveredURLMigration.discoveredExternalURLKey) == nil)
        #expect(d.string(forKey: DiscoveredURLMigration.lastWorkingURLKey) == nil)
    }

    @Test func migrationRunsExactlyOnce() {
        let d = freshDefaults("migrationOnce")
        d.set("https://attacker.ui.nabu.casa", forKey: DiscoveredURLMigration.discoveredExternalURLKey)
        #expect(DiscoveredURLMigration.runIfNeeded(in: d))
        #expect(d.string(forKey: DiscoveredURLMigration.discoveredExternalURLKey) == nil)

        // THE TRAP: a URL adopted after the migration ran must survive every subsequent call —
        // this stands in for the next iteration of `connect()`'s loop.
        d.set("https://abc123.ui.nabu.casa", forKey: DiscoveredURLMigration.discoveredExternalURLKey)
        d.set("http://192.168.1.42:8123", forKey: DiscoveredURLMigration.discoveredInternalURLKey)
        d.set("http://192.168.1.42:8123", forKey: DiscoveredURLMigration.lastWorkingURLKey)

        #expect(!DiscoveredURLMigration.runIfNeeded(in: d))
        #expect(!DiscoveredURLMigration.runIfNeeded(in: d))

        #expect(d.string(forKey: DiscoveredURLMigration.discoveredExternalURLKey) == "https://abc123.ui.nabu.casa")
        #expect(d.string(forKey: DiscoveredURLMigration.discoveredInternalURLKey) == "http://192.168.1.42:8123")
        #expect(d.string(forKey: DiscoveredURLMigration.lastWorkingURLKey) == "http://192.168.1.42:8123")
    }

    @Test func migrationMarksItselfDoneEvenOnADeviceWithNothingStored() {
        // Otherwise a clean install would "migrate" on every launch — harmless today, but it is
        // the same shape as the trap and would come back the moment the migration does more.
        let d = freshDefaults("migrationCleanInstall")
        #expect(DiscoveredURLMigration.runIfNeeded(in: d))
        #expect(!DiscoveredURLMigration.runIfNeeded(in: d))
        #expect(d.bool(forKey: DiscoveredURLMigration.didClearOvernightURLsKey))
    }

    // MARK: - ConnectionEndpoint.candidates — ordering and classification

    @Test func userEnteredOwnNabuCasaURLStillWorksDirectly() {
        // A user who *typed* their own Nabu Casa address (or had it restored from a previous
        // sign-in) gets it classified remote — `isNabuCasaHost` doing the job it is actually for.
        let candidates = ConnectionEndpoint.candidates(
            userEntered: url("https://abc123.ui.nabu.casa"),
            discoveredInternal: nil,
            discoveredExternal: nil
        )
        #expect(candidates == [.remote(url("https://abc123.ui.nabu.casa"))])
    }

    @Test func singleUserEnteredURLYieldsOneLocalCandidate() {
        let candidates = ConnectionEndpoint.candidates(
            userEntered: url("http://homeassistant.local:8123"),
            discoveredInternal: nil,
            discoveredExternal: nil
        )
        #expect(candidates == [.local(url("http://homeassistant.local:8123"))])
    }

    @Test func localBeforeRemoteByDefault() {
        let candidates = ConnectionEndpoint.candidates(
            userEntered: url("http://192.168.1.42:8123"),
            discoveredInternal: nil,
            discoveredExternal: url("https://myinstance.duckdns.org:8123")
        )
        #expect(candidates == [
            .local(url("http://192.168.1.42:8123")),
            .remote(url("https://myinstance.duckdns.org:8123")),
        ])
    }

    @Test func nabuCasaHostIsAlwaysRemoteEvenAsUserEnteredURL() {
        // e.g. a user who signed in directly against their Nabu Casa URL, with no local address
        // known at all yet.
        let candidates = ConnectionEndpoint.candidates(
            userEntered: url("https://abc123.ui.nabu.casa"),
            discoveredInternal: nil,
            discoveredExternal: nil
        )
        #expect(candidates == [.remote(url("https://abc123.ui.nabu.casa"))])
    }

    @Test func remoteCandidatesAreAlwaysUpgradedToHTTPS() {
        // get_config's external_url could in principle come back as plain http (a self-hosted
        // reverse proxy misconfiguration, or just how HA has it stored) — remote candidates must
        // always be https/wss regardless.
        let candidates = ConnectionEndpoint.candidates(
            userEntered: url("http://192.168.1.42:8123"),
            discoveredInternal: nil,
            discoveredExternal: url("http://abc123.ui.nabu.casa")
        )
        #expect(candidates == [
            .local(url("http://192.168.1.42:8123")),
            .remote(url("https://abc123.ui.nabu.casa")),
        ])
    }

    @Test func userEnteredNabuCasaHostOverHTTPIsUpgradedToHTTPS() {
        let candidates = ConnectionEndpoint.candidates(
            userEntered: url("http://abc123.ui.nabu.casa"),
            discoveredInternal: nil,
            discoveredExternal: nil
        )
        #expect(candidates == [.remote(url("https://abc123.ui.nabu.casa"))])
    }

    @Test func duplicateURLsAreCollapsed() {
        // The common steady state: get_config's internal_url echoes back the same address the
        // user already typed.
        let candidates = ConnectionEndpoint.candidates(
            userEntered: url("http://192.168.1.42:8123"),
            discoveredInternal: url("http://192.168.1.42:8123"),
            discoveredExternal: nil
        )
        #expect(candidates == [.local(url("http://192.168.1.42:8123"))])
    }

    @Test func discoveredInternalAndUserEnteredBothLocalAndDistinctKeepBothInOrder() {
        let candidates = ConnectionEndpoint.candidates(
            userEntered: url("http://homeassistant.local:8123"),
            discoveredInternal: url("http://192.168.1.42:8123"),
            discoveredExternal: nil
        )
        // discoveredInternal is appended before userEntered in the local-leaning group.
        #expect(candidates == [
            .local(url("http://192.168.1.42:8123")),
            .local(url("http://homeassistant.local:8123")),
        ])
    }

    @Test func neverEmptyWhenOnlyExternalIsKnown() {
        let candidates = ConnectionEndpoint.candidates(
            userEntered: nil,
            discoveredInternal: nil,
            discoveredExternal: url("https://abc123.ui.nabu.casa")
        )
        #expect(candidates == [.remote(url("https://abc123.ui.nabu.casa"))])
    }

    @Test func allNilYieldsEmptyList() {
        // Not "never empty" in the absolute sense — only when at least one URL is known.
        let candidates = ConnectionEndpoint.candidates(
            userEntered: nil,
            discoveredInternal: nil,
            discoveredExternal: nil
        )
        #expect(candidates.isEmpty)
    }

    @Test func preferredFirstHoistsAKnownRemoteCandidateAheadOfLocal() {
        let candidates = ConnectionEndpoint.candidates(
            userEntered: url("http://192.168.1.42:8123"),
            discoveredInternal: nil,
            discoveredExternal: url("https://abc123.ui.nabu.casa"),
            preferredFirst: url("https://abc123.ui.nabu.casa")
        )
        #expect(candidates == [
            .remote(url("https://abc123.ui.nabu.casa")),
            .local(url("http://192.168.1.42:8123")),
        ])
    }

    @Test func preferredFirstThatIsAlreadyFirstIsANoOp() {
        let candidates = ConnectionEndpoint.candidates(
            userEntered: url("http://192.168.1.42:8123"),
            discoveredInternal: nil,
            discoveredExternal: url("https://abc123.ui.nabu.casa"),
            preferredFirst: url("http://192.168.1.42:8123")
        )
        #expect(candidates == [
            .local(url("http://192.168.1.42:8123")),
            .remote(url("https://abc123.ui.nabu.casa")),
        ])
    }

    @Test func preferredFirstNotAmongKnownCandidatesIsIgnored() {
        let candidates = ConnectionEndpoint.candidates(
            userEntered: url("http://192.168.1.42:8123"),
            discoveredInternal: nil,
            discoveredExternal: nil,
            preferredFirst: url("https://someone-elses-instance.ui.nabu.casa")
        )
        #expect(candidates == [.local(url("http://192.168.1.42:8123"))])
    }

    @Test func candidateURLPropertyRoundTrips() {
        #expect(ConnectionEndpoint.local(url("http://a:1")).url == url("http://a:1"))
        #expect(ConnectionEndpoint.remote(url("https://b:2")).url == url("https://b:2"))
    }

    @Test func isRemoteReflectsCase() {
        #expect(!ConnectionEndpoint.local(url("http://a:1")).isRemote)
        #expect(ConnectionEndpoint.remote(url("https://b:2")).isRemote)
    }

    @Test func differentPortsOnSameHostAreNotDuplicates() {
        let candidates = ConnectionEndpoint.candidates(
            userEntered: url("http://192.168.1.42:8123"),
            discoveredInternal: url("http://192.168.1.42:8443"),
            discoveredExternal: nil
        )
        #expect(candidates.count == 2)
    }

    @Test func allThreeSourcesDistinctYieldsAllThreeOrderedLocalFirst() {
        let candidates = ConnectionEndpoint.candidates(
            userEntered: url("http://homeassistant.local:8123"),
            discoveredInternal: url("http://192.168.1.42:8123"),
            discoveredExternal: url("https://abc123.ui.nabu.casa")
        )
        #expect(candidates == [
            .local(url("http://192.168.1.42:8123")),
            .local(url("http://homeassistant.local:8123")),
            .remote(url("https://abc123.ui.nabu.casa")),
        ])
    }
}
