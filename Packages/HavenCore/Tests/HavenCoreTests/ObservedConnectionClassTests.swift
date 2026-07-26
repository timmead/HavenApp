import Testing
import Foundation
import Network
@testable import HavenCore

/// The private-range test that decides whether a live connection may be trusted.
///
/// This is the security input `DiscoveredCandidateURLs.validating` is keyed on: `.local` here means
/// `get_config`'s `external_url` gets adopted as a permanent connection candidate that
/// `TokenProvider` will later POST the refresh token to. Every case below pairs a range with its
/// **nearest non-member**, because an off-by-one in a range check is exactly the kind of mistake
/// that is invisible in review and catastrophic in effect.
@Suite struct ObservedConnectionClassTests {

    // MARK: - IPv4 private ranges, each against its nearest public neighbour

    @Test func loopbackIsLocal() {
        #expect(ConnectionClass.observed(peerAddress: "127.0.0.1") == .local)
        #expect(ConnectionClass.observed(peerAddress: "127.255.255.254") == .local)
        // 126/8 and 128/8 are ordinary public space either side of 127/8.
        #expect(ConnectionClass.observed(peerAddress: "126.0.0.1") == .remote)
        #expect(ConnectionClass.observed(peerAddress: "128.0.0.1") == .remote)
    }

    @Test func tenSlashEightIsLocalAndElevenIsNot() {
        #expect(ConnectionClass.observed(peerAddress: "10.0.0.1") == .local)
        #expect(ConnectionClass.observed(peerAddress: "10.255.255.255") == .local)
        #expect(ConnectionClass.observed(peerAddress: "11.0.0.1") == .remote)
        #expect(ConnectionClass.observed(peerAddress: "9.255.255.255") == .remote)
    }

    @Test func the172RangeIsExactly16Through31() {
        // The classic off-by-one: 172/8 is NOT private, only 172.16/12 is.
        #expect(ConnectionClass.observed(peerAddress: "172.15.0.1") == .remote)
        #expect(ConnectionClass.observed(peerAddress: "172.16.0.1") == .local)
        #expect(ConnectionClass.observed(peerAddress: "172.31.255.254") == .local)
        #expect(ConnectionClass.observed(peerAddress: "172.32.0.1") == .remote)
    }

    @Test func only192Dot168IsLocalNot192Dot167Or192Dot169() {
        #expect(ConnectionClass.observed(peerAddress: "192.168.0.1") == .local)
        #expect(ConnectionClass.observed(peerAddress: "192.168.255.254") == .local)
        #expect(ConnectionClass.observed(peerAddress: "192.167.1.1") == .remote)
        #expect(ConnectionClass.observed(peerAddress: "192.169.1.1") == .remote)
    }

    @Test func linkLocal169Dot254IsLocalButTheRestOf169IsNot() {
        #expect(ConnectionClass.observed(peerAddress: "169.254.10.20") == .local)
        #expect(ConnectionClass.observed(peerAddress: "169.253.10.20") == .remote)
        #expect(ConnectionClass.observed(peerAddress: "169.255.10.20") == .remote)
    }

    @Test func ordinaryPublicAddressesAreRemote() {
        #expect(ConnectionClass.observed(peerAddress: "8.8.8.8") == .remote)
        #expect(ConnectionClass.observed(peerAddress: "1.1.1.1") == .remote)
        #expect(ConnectionClass.observed(peerAddress: "104.21.5.7") == .remote)
    }

    /// A deliberate, load-bearing decision — do not "fix" this into the private list.
    ///
    /// `100.64/10` is RFC 6598 carrier-grade NAT space, and it is where a **Tailscale** peer lands.
    /// A Tailscale connection is encrypted and authenticated, and is very plausibly the user's own
    /// machine — but it is not the LAN, and the trust model's rule is about *where a fact was
    /// learned*, not about how good the transport is. Classifying it `.remote` costs one thing: the
    /// user's `get_config` URLs aren't auto-adopted over it, and they enter a remote URL by hand
    /// (that is exactly what plan Task 6's custom-remote-URL path is for). Classifying it `.local`
    /// would mean any connection that merely *looked* like it came over a private-ish tunnel could
    /// nominate a new token-receiving host.
    @Test func cgnatSpaceWhereTailscalePeersLiveIsDeliberatelyRemote() {
        #expect(ConnectionClass.observed(peerAddress: "100.64.0.1") == .remote)
        #expect(ConnectionClass.observed(peerAddress: "100.100.100.100") == .remote)
        #expect(ConnectionClass.observed(peerAddress: "100.127.255.255") == .remote)
    }

    // MARK: - IPv6

    @Test func ipv6LoopbackIsLocal() {
        #expect(ConnectionClass.observed(peerAddress: "::1") == .local)
    }

    @Test func theUnspecifiedIPv6AddressIsNotLocal() {
        // `::` is "no address", not "my address" — one bit away from ::1 and not a peer at all.
        #expect(ConnectionClass.observed(peerAddress: "::") == .remote)
    }

    @Test func ipv6UniqueLocalAddressesAreLocal() {
        // fc00::/7 covers both fc00::/8 and fd00::/8; fd is what real deployments use.
        #expect(ConnectionClass.observed(peerAddress: "fc00::1") == .local)
        #expect(ConnectionClass.observed(peerAddress: "fd12:3456:789a::1") == .local)
        #expect(ConnectionClass.observed(peerAddress: "fdff:ffff:ffff:ffff::1") == .local)
    }

    @Test func ipv6LinkLocalIsLocalIncludingWithAZoneSuffix() {
        #expect(ConnectionClass.observed(peerAddress: "fe80::1") == .local)
        // Network.framework reports link-local addresses with the interface zone attached; the
        // classifier must not choke on it and fail closed on a genuinely local connection.
        #expect(ConnectionClass.observed(peerAddress: "fe80::1cb2:3f4d:5e6f:7a8b%en0") == .local)
        // fe80::/10 ends at febf; fec0:: is (deprecated) site-local, outside the range.
        #expect(ConnectionClass.observed(peerAddress: "febf::1") == .local)
        #expect(ConnectionClass.observed(peerAddress: "fec0::1") == .remote)
    }

    /// A globally-routable IPv6 address is `.remote` **even if the host is physically on the LAN**.
    ///
    /// This is the accepted cost of the fail-closed rule, not an oversight: a GUA handed out by
    /// SLAAC is indistinguishable, from the address alone, from a host on the internet. Such a
    /// setup never auto-learns its remote URL and the user types one instead. The reverse mistake
    /// — treating an internet peer as local — adopts an attacker's URL permanently.
    @Test func publicIPv6IsRemote() {
        #expect(ConnectionClass.observed(peerAddress: "2001:4860:4860::8888") == .remote)
        #expect(ConnectionClass.observed(peerAddress: "2600:1901::1") == .remote)
    }

    @Test func ipv4MappedIPv6IsJudgedOnTheEmbeddedIPv4Address() {
        // ::ffff:a.b.c.d carries real IPv4 traffic. Judging the wrapper instead of the payload
        // would make ::ffff:8.8.8.8 and ::ffff:192.168.1.1 indistinguishable — both merely "not
        // fc00::/7" — and quietly classify Google's DNS the same as the user's router.
        #expect(ConnectionClass.observed(peerAddress: "::ffff:192.168.1.10") == .local)
        #expect(ConnectionClass.observed(peerAddress: "::ffff:10.0.0.5") == .local)
        #expect(ConnectionClass.observed(peerAddress: "::ffff:8.8.8.8") == .remote)
        #expect(ConnectionClass.observed(peerAddress: "::ffff:100.64.0.1") == .remote)
    }

    // MARK: - Fail closed

    @Test func anUnavailableAddressFailsClosedToRemote() {
        // The whole point of the fail-closed rule: "we could not tell" must never mean "trusted".
        #expect(ConnectionClass.observed(peerAddress: nil) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "") == .remote)
    }

    @Test func garbageAndUnresolvedHostnamesFailClosedToRemote() {
        #expect(ConnectionClass.observed(peerAddress: "banana") == .remote)
        // A hostname is not an address, however local it looks. This is the exact confusion the
        // removed `ConnectionEndpoint.connectionClass` embodied.
        #expect(ConnectionClass.observed(peerAddress: "homeassistant.local") == .remote)
        #expect(ConnectionClass.observed(peerAddress: "192.168.1") == .remote)
        #expect(ConnectionClass.observed(peerAddress: "192.168.1.1.1") == .remote)
        #expect(ConnectionClass.observed(peerAddress: "192.168.1.256") == .remote)
        #expect(ConnectionClass.observed(peerAddress: "192.168.-1.1") == .remote)
    }

    /// `IPv4Address(String)` inherits `inet_aton`'s leniency — it reads `"10.1"` as `10.0.0.1` and
    /// `"0xc0a80101"` as `192.168.1.1` (both verified against the framework). Every one of those
    /// alternative spellings can only ever *widen* the private ranges, on a value that decides
    /// whether a connection is trusted, so the parser feeding this accepts dotted-quad and nothing
    /// else. If someone swaps it for `IPv4Address(_:)` "to simplify", these fail.
    @Test func shorthandAndHexIPv4SpellingsAreRejectedRatherThanExpandedIntoPrivateRanges() {
        #expect(ConnectionClass.observed(peerAddress: "10.1") == .remote)
        #expect(ConnectionClass.observed(peerAddress: "0xc0a80101") == .remote)
        #expect(ConnectionClass.observed(peerAddress: "0x7f000001") == .remote)
        #expect(ConnectionClass.observed(peerAddress: "2130706433") == .remote)
        #expect(ConnectionClass.observed(peerAddress: " 10.0.0.1") == .remote)
        #expect(ConnectionClass.observed(peerAddress: "10.0.0.1 ") == .remote)
    }

    // MARK: - Endpoint → address string

    @Test func addressIsExtractedFromResolvedIPv4AndIPv6Endpoints() {
        let v4 = NWEndpoint.hostPort(host: .ipv4(IPv4Address("192.168.1.10")!), port: 8123)
        #expect(PeerEndpointAddress.address(of: v4) == "192.168.1.10")
        let v6 = NWEndpoint.hostPort(host: .ipv6(IPv6Address("fd00::1")!), port: 8123)
        #expect(PeerEndpointAddress.address(of: v6) == "fd00::1")
    }

    @Test func anUnresolvedNameEndpointYieldsNoAddressAndSoClassifiesRemote() {
        let named = NWEndpoint.hostPort(host: .name("homeassistant.local", nil), port: 8123)
        #expect(PeerEndpointAddress.address(of: named) == nil)
        #expect(ConnectionClass.observed(peerAddress: PeerEndpointAddress.address(of: named)) == .remote)
    }

    @Test func aMissingOrNonHostPortEndpointYieldsNoAddress() {
        #expect(PeerEndpointAddress.address(of: nil) == nil)
        #expect(PeerEndpointAddress.address(of: .service(name: "ha", type: "_http._tcp", domain: "local", interface: nil)) == nil)
    }

    // MARK: - `onKnownHomeNetwork` — the SSID signal that closes the IPv6-GUA gap

    /// The IP signal alone is untouched: a private address is still `.local` whether or not the
    /// caller even knows about SSIDs, matched or not.
    @Test func privateAddressIsLocalRegardlessOfSSIDSignal() {
        #expect(ConnectionClass.observed(peerAddress: "192.168.1.10", onKnownHomeNetwork: false) == .local)
        #expect(ConnectionClass.observed(peerAddress: "192.168.1.10", onKnownHomeNetwork: nil) == .local)
    }

    /// This is the case the parameter exists for: a globally-routable IPv6 address — indistinguishable
    /// from an internet host by address alone — is `.local` once the current Wi-Fi is known to match
    /// the user's configured home network.
    @Test func publicGUAWithMatchingSSIDIsLocal() {
        #expect(ConnectionClass.observed(peerAddress: "2600:1901::1", onKnownHomeNetwork: true) == .local)
    }

    @Test func publicGUAWithNoSSIDMatchIsStillRemote() {
        #expect(ConnectionClass.observed(peerAddress: "2600:1901::1", onKnownHomeNetwork: false) == .remote)
    }

    /// `nil` — SSID unknown, e.g. Location Services not authorized — must behave exactly like
    /// `false`, not like `true`. This is the fail-closed rule from `homeSSIDMatch` propagated all the
    /// way through, and it is what keeps this change from being a loosening for every user who never
    /// grants the permission — unchanged from Task 4's behaviour.
    @Test func publicGUAWithUnknownSSIDIsRemoteUnchangedFromBeforeThisSignalExisted() {
        #expect(ConnectionClass.observed(peerAddress: "2600:1901::1", onKnownHomeNetwork: nil) == .remote)
    }

    /// An unresolved/unavailable address is still `.remote` unless the SSID signal says otherwise —
    /// the two signals are a genuine OR, neither one gates the other.
    @Test func unavailableAddressWithMatchingSSIDIsStillLocal() {
        #expect(ConnectionClass.observed(peerAddress: nil, onKnownHomeNetwork: true) == .local)
    }
}
