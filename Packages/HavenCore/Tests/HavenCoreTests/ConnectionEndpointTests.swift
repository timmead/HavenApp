import Testing
import Foundation
@testable import HavenCore

@Suite struct ConnectionEndpointTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

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
