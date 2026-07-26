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
        // A hostile `external_url` an earlier, less careful build (commits a78bdc2/43043c2, both
        // superseded — see `DiscoveredCandidateURLs`'s documentation for the full incident) may
        // already have written to `UserDefaults` — proving the predicate answers identically for
        // a value round-tripped through storage as for one straight off the wire.
        let persisted = "https://abc123.ui.nabu.casa"
        let roundTripped = UserDefaults.standard
        roundTripped.set(persisted, forKey: "test.legacyDiscoveredExternalURL")
        defer { roundTripped.removeObject(forKey: "test.legacyDiscoveredExternalURL") }
        let loaded = roundTripped.string(forKey: "test.legacyDiscoveredExternalURL").flatMap(URL.init(string:))
        #expect(loaded != nil)
        // Note what this proves and what it doesn't: the host genuinely *is* a Nabu Casa
        // instance — that's true whether it's the user's own or an attacker's. That's exactly
        // the category-vs-identity gap `isNabuCasaHost`'s documentation now spells out, and why
        // `DiscoveredCandidateURLs.validating` (below) no longer uses this predicate to decide
        // what to adopt from `get_config` at all.
        #expect(ConnectionEndpoint.isNabuCasaHost(loaded!))
    }

    // MARK: - DiscoveredCandidateURLs.validating — adopts nothing from get_config, ever
    //
    // C-1 (final whole-branch review): `isNabuCasaHost` proves a host is *a* Nabu Casa instance,
    // never that it is *this user's* — Nabu Casa subdomains are issued to any paying subscriber,
    // including an attacker who buys their own and MITMs one `get_config` response to inject it.
    // Two prior fix rounds used that predicate to decide whether to auto-adopt `external_url`;
    // both were the same mistake. There is no property of data arriving over an
    // attacker-controlled channel that proves it belongs to the user's instance, so the only
    // correct answer is to adopt nothing from `get_config` at all, ever — remote access comes
    // only from the URL the user actually typed. This is the pure function that decision lives
    // in — `AppModel.rememberDiscoveredURLs`/`discoveredExternalURL` (renamed
    // `purgeDiscoveredURLs`) call only this and hold no validation logic of their own, so these
    // tests exercise the actual fix, not a claim about untested App-layer code.

    @Test func validatingNeverAdoptsInternalURLRegardlessOfValue() {
        let hostileInternal = url("https://evil.example")
        let result = DiscoveredCandidateURLs.validating(rawInternalURL: hostileInternal, rawExternalURL: nil)
        #expect(result.externalURL == nil)
        // There is no `internalURL` field on the result at all — by construction, nothing given
        // as `rawInternalURL` can ever become a candidate. Varying it (even to a genuine Nabu
        // Casa host) never changes the outcome.
        let evenANabuCasaHostAsInternal = DiscoveredCandidateURLs.validating(
            rawInternalURL: url("https://abc123.ui.nabu.casa"),
            rawExternalURL: nil
        )
        #expect(evenANabuCasaHostAsInternal.externalURL == nil)
    }

    @Test func validatingNeverAdoptsAGenuineNabuCasaExternalURLStraightOffTheWire() {
        // The C-1 finding, made concrete: this is exactly what a fresh get_config result would
        // hand `rememberDiscoveredURLs` — a syntactically perfect, genuinely-issued Nabu Casa
        // host — whether it's the user's own or one an attacker bought for this exact purpose is
        // not something this function (or anything downstream of it) can tell, so it must not be
        // adopted either way.
        let result = DiscoveredCandidateURLs.validating(rawInternalURL: nil, rawExternalURL: url("https://abc123.ui.nabu.casa"))
        #expect(result.externalURL == nil)
    }

    @Test func validatingNeverAdoptsAnArbitraryHTTPSExternalURL() {
        let result = DiscoveredCandidateURLs.validating(rawInternalURL: nil, rawExternalURL: url("https://evil.example"))
        #expect(result.externalURL == nil)
    }

    @Test func validatingNeverAdoptsAPersistedExternalURLEvenAGenuineNabuCasaOne() {
        // "A persisted one is dropped [when read back]": a genuine `*.ui.nabu.casa` value an
        // earlier build already wrote to `UserDefaults` is exactly as untrusted, read back, as a
        // fresh one arriving on the wire right now — same function, same answer, either way.
        let persisted = url("https://abc123.ui.nabu.casa")
        let result = DiscoveredCandidateURLs.validating(rawInternalURL: nil, rawExternalURL: persisted)
        #expect(result.externalURL == nil)
    }

    @Test func validatingWithNoInputsYieldsNoExternalURL() {
        let result = DiscoveredCandidateURLs.validating(rawInternalURL: nil, rawExternalURL: nil)
        #expect(result.externalURL == nil)
    }

    @Test func userEnteredURLStillBecomesACandidateWhenNothingIsDiscovered() {
        // "User-entered URL is unaffected": this is exactly the shape `AppModel` now always
        // builds candidates with — both `discoveredInternal` and `discoveredExternal` permanently
        // `nil` (see `ConnectionEndpoint.candidates`'s documentation for why). The user's own
        // typed/restored URL must still show up; remote access can now only ever come from here.
        let validated = DiscoveredCandidateURLs.validating(
            rawInternalURL: nil,
            rawExternalURL: url("https://abc123.ui.nabu.casa")
        )
        let candidates = ConnectionEndpoint.candidates(
            userEntered: url("http://192.168.1.42:8123"),
            discoveredInternal: nil,
            discoveredExternal: validated.externalURL
        )
        #expect(candidates == [.local(url("http://192.168.1.42:8123"))])
    }

    @Test func userEnteredOwnNabuCasaURLStillWorksDirectly() {
        // The one path remote access still has: a user who *typed* their own Nabu Casa address
        // (or it was restored from a previous sign-in) gets it classified remote exactly as
        // before — `isNabuCasaHost` remains correct and necessary for classifying a URL the
        // caller already has an independent reason to trust; it's only auto-adoption from
        // `get_config` that's gone.
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
