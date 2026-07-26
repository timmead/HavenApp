import Testing
import Foundation
@testable import HavenCore

@Suite struct ConnectionEndpointTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: - isNabuCasaHost — the security-critical adopt/reject predicate
    //
    // `AppModel` calls this exact function at both boundaries around a discovered `external_url`:
    // once when `get_config`'s result first arrives off the wire (write boundary,
    // `rememberDiscoveredURLs`), and again every time a previously-persisted value is loaded back
    // out of `UserDefaults` (read boundary, `discoveredURLs()`/`lastWorkingURL()`) — the latter so
    // a hostile value written by an earlier, unvalidated build doesn't keep being trusted forever
    // just because it's already on disk. Being a pure function in HavenCore is what makes both of
    // those call sites (and this reuse) actually verifiable, since there is no App-layer test
    // target `AppModel` itself could be exercised from.

    @Test func isNabuCasaHostAdoptsAGenuineNabuCasaHost() {
        #expect(ConnectionEndpoint.isNabuCasaHost(url("https://abc123.ui.nabu.casa")))
    }

    @Test func isNabuCasaHostRejectsAnArbitraryHTTPSHost() {
        // The core I-3 attack: an on-LAN MITM injects this as get_config's external_url so it
        // gets tried — and trusted with the refresh token — later, off-network.
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

    @Test func isNabuCasaHostRejectsAHostileValueArrivingFromPersistedState() {
        // Simulates constraint A of the I-3 fix: a hostile `external_url` an earlier,
        // unvalidated build (commit a78bdc2) already wrote to UserDefaults with no check at all.
        // `AppModel.discoveredURLs()` round-trips exactly this way (read the stored string, parse
        // it back to a URL, run it through this same predicate) before ever treating it as a
        // candidate — proving the predicate rejects it identically regardless of whether it just
        // arrived on the wire or was already sitting in persisted state from before this fix
        // existed.
        let persisted = "https://evil.example"
        let roundTripped = UserDefaults.standard
        roundTripped.set(persisted, forKey: "test.legacyDiscoveredExternalURL")
        defer { roundTripped.removeObject(forKey: "test.legacyDiscoveredExternalURL") }
        let loaded = roundTripped.string(forKey: "test.legacyDiscoveredExternalURL").flatMap(URL.init(string:))
        #expect(loaded != nil)
        #expect(!ConnectionEndpoint.isNabuCasaHost(loaded!))
    }

    // MARK: - DiscoveredCandidateURLs.validating — the whole stored-state → candidate decision
    //
    // Fix round 1 validated `external_url` but left `internal_url` completely unchecked — the
    // exact same attack (a MITM'd get_config injecting a hostile host) through the adjacent
    // field, since internal_url was classified `.local` for any non-Nabu-Casa host and appended
    // as a candidate *ahead of* the user-entered URL. `internal_url` cannot be validated as "a
    // private address" inside this app's threat model (see `DiscoveredCandidateURLs`'s doc), so
    // it is dropped unconditionally rather than checked. This is the pure function that decision
    // lives in — `AppModel.rememberDiscoveredURLs`/`discoveredExternalURL` call only this and
    // hold no validation logic of their own, so these tests exercise the actual fix, not a claim
    // about untested App-layer code.

    @Test func validatingNeverAdoptsInternalURLRegardlessOfValue() {
        // "Hostile internal_url straight off the wire is never persisted": simulates
        // `rememberDiscoveredURLs` receiving a `get_config` result where a MITM injected a
        // hostile `internal_url` instead of `external_url`.
        let hostileInternal = url("https://evil.example")
        let result = DiscoveredCandidateURLs.validating(rawInternalURL: hostileInternal, rawExternalURL: nil)
        #expect(result.externalURL == nil)
        // There is no `internalURL` field on the result at all — by construction, nothing given
        // as `rawInternalURL` can ever become a candidate. Varying it (even to a Nabu-Casa host,
        // which would very much matter if this were `rawExternalURL`) never changes the outcome.
        let evenANabuCasaHostAsInternal = DiscoveredCandidateURLs.validating(
            rawInternalURL: url("https://abc123.ui.nabu.casa"),
            rawExternalURL: nil
        )
        #expect(evenANabuCasaHostAsInternal.externalURL == nil)
    }

    @Test func validatingDropsAHostileInternalURLEvenWhenAGenuineExternalURLIsAlsoPresent() {
        // Proves the two fields are decided independently: a hostile internal_url alongside a
        // legitimate external_url doesn't taint or otherwise affect the external_url outcome.
        let result = DiscoveredCandidateURLs.validating(
            rawInternalURL: url("https://evil.example"),
            rawExternalURL: url("https://abc123.ui.nabu.casa")
        )
        #expect(result.externalURL == url("https://abc123.ui.nabu.casa"))
    }

    @Test func validatingRejectsAHostileExternalURLStraightOffTheWire() {
        let result = DiscoveredCandidateURLs.validating(rawInternalURL: nil, rawExternalURL: url("https://evil.example"))
        #expect(result.externalURL == nil)
    }

    @Test func validatingAcceptsAGenuineNabuCasaExternalURL() {
        // "A legitimate *.ui.nabu.casa external_url still survives both boundaries": this same
        // function is called identically at the write boundary (a fresh get_config result) and
        // the read boundary (a value loaded back from UserDefaults) — there's only one code path
        // to prove this for.
        let result = DiscoveredCandidateURLs.validating(rawInternalURL: nil, rawExternalURL: url("https://abc123.ui.nabu.casa"))
        #expect(result.externalURL == url("https://abc123.ui.nabu.casa"))
    }

    @Test func validatingWithNoInputsYieldsNoExternalURL() {
        let result = DiscoveredCandidateURLs.validating(rawInternalURL: nil, rawExternalURL: nil)
        #expect(result.externalURL == nil)
    }

    @Test func userEnteredURLStillBecomesACandidateWhenDiscoveredInternalIsNil() {
        // "User-entered URL is unaffected": this is exactly the shape `AppModel` now always
        // builds candidates with — `discoveredInternal` permanently `nil` (see
        // `ConnectionEndpoint.candidates`'s documentation for why) and `discoveredExternal` from
        // `DiscoveredCandidateURLs`. The user's own typed/restored URL must still show up.
        let validated = DiscoveredCandidateURLs.validating(
            rawInternalURL: nil,
            rawExternalURL: url("https://abc123.ui.nabu.casa")
        )
        let candidates = ConnectionEndpoint.candidates(
            userEntered: url("http://192.168.1.42:8123"),
            discoveredInternal: nil,
            discoveredExternal: validated.externalURL
        )
        #expect(candidates == [
            .local(url("http://192.168.1.42:8123")),
            .remote(url("https://abc123.ui.nabu.casa")),
        ])
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
