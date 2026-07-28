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
        #expect(ConnectionClass.observed(peerAddress: "127.0.0.1", dialledRemoteCandidate: false) == .local)
        #expect(ConnectionClass.observed(peerAddress: "127.255.255.254", dialledRemoteCandidate: false) == .local)
        // 126/8 and 128/8 are ordinary public space either side of 127/8.
        #expect(ConnectionClass.observed(peerAddress: "126.0.0.1", dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "128.0.0.1", dialledRemoteCandidate: false) == .remote)
    }

    @Test func tenSlashEightIsLocalAndElevenIsNot() {
        #expect(ConnectionClass.observed(peerAddress: "10.0.0.1", dialledRemoteCandidate: false) == .local)
        #expect(ConnectionClass.observed(peerAddress: "10.255.255.255", dialledRemoteCandidate: false) == .local)
        #expect(ConnectionClass.observed(peerAddress: "11.0.0.1", dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "9.255.255.255", dialledRemoteCandidate: false) == .remote)
    }

    @Test func the172RangeIsExactly16Through31() {
        // The classic off-by-one: 172/8 is NOT private, only 172.16/12 is.
        #expect(ConnectionClass.observed(peerAddress: "172.15.0.1", dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "172.16.0.1", dialledRemoteCandidate: false) == .local)
        #expect(ConnectionClass.observed(peerAddress: "172.31.255.254", dialledRemoteCandidate: false) == .local)
        #expect(ConnectionClass.observed(peerAddress: "172.32.0.1", dialledRemoteCandidate: false) == .remote)
    }

    @Test func only192Dot168IsLocalNot192Dot167Or192Dot169() {
        #expect(ConnectionClass.observed(peerAddress: "192.168.0.1", dialledRemoteCandidate: false) == .local)
        #expect(ConnectionClass.observed(peerAddress: "192.168.255.254", dialledRemoteCandidate: false) == .local)
        #expect(ConnectionClass.observed(peerAddress: "192.167.1.1", dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "192.169.1.1", dialledRemoteCandidate: false) == .remote)
    }

    @Test func linkLocal169Dot254IsLocalButTheRestOf169IsNot() {
        #expect(ConnectionClass.observed(peerAddress: "169.254.10.20", dialledRemoteCandidate: false) == .local)
        #expect(ConnectionClass.observed(peerAddress: "169.253.10.20", dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "169.255.10.20", dialledRemoteCandidate: false) == .remote)
    }

    /// **The address Network.framework actually reports, from a real device log:**
    ///
    /// ```
    /// peer address 192.168.1.42%en0, SSID match unknown → classified remote
    /// cloud/status → remoteAvailable(https://….ui.nabu.casa); no remote URL adopted
    /// ```
    ///
    /// `NWPath.remoteEndpoint` appends the interface the socket is bound to, and it does so for
    /// IPv4 as well as IPv6. `strictIPv4Octets` splits on `.` and then fails on `"42%en0"`, so a
    /// plainly private LAN address fell through to the fail-closed branch and the whole connection
    /// was classified `.remote`.
    ///
    /// It failed *safe* — nothing untrusted was ever adopted — but the cost is that nothing
    /// trusted was either: `get_config`'s URLs were discarded, the home Wi-Fi was never captured,
    /// and the Nabu Casa remote URL was never remembered. Which means that away from home the app
    /// has no remote address to fall back on, and the entire local/remote failover it is built
    /// around never engages.
    ///
    /// The IPv6 side of this was thought about and tested from the start
    /// (`ipv6LinkLocalIsLocalIncludingWithAZoneSuffix`) — `IPv6Address` accepts a zone identifier
    /// natively, so it never broke. The IPv4 equivalent was simply never written, which is why a
    /// bug this visible survived: the parser had 100% of the spellings anyone thought to test.
    @Test func ipv4IsLocalIncludingWithAZoneSuffix() {
        #expect(ConnectionClass.observed(peerAddress: "192.168.1.42%en0",
                                         dialledRemoteCandidate: false) == .local)
        #expect(ConnectionClass.observed(peerAddress: "10.0.0.5%en0",
                                         dialledRemoteCandidate: false) == .local)
        #expect(ConnectionClass.observed(peerAddress: "127.0.0.1%lo0",
                                         dialledRemoteCandidate: false) == .local)
    }

    /// **The half of the fix that must not move.** Stripping the interface qualifier may only ever
    /// make an address *parseable*; it must never make a public one look private. A zone is not
    /// address data, so the bits being judged are identical either way — and this is what holds
    /// that true.
    @Test func aZoneSuffixDoesNotMakeAPublicAddressLocal() {
        #expect(ConnectionClass.observed(peerAddress: "8.8.8.8%en0",
                                         dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "100.64.0.1%utun0",
                                         dialledRemoteCandidate: false) == .remote)
        // Nothing before the qualifier is not an address at all.
        #expect(ConnectionClass.observed(peerAddress: "%en0",
                                         dialledRemoteCandidate: false) == .remote)
        // The strictness the parser exists for survives the strip: shorthand and hex spellings are
        // still refused rather than expanded into private ranges.
        #expect(ConnectionClass.observed(peerAddress: "10.1%en0",
                                         dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "0x7f000001%en0",
                                         dialledRemoteCandidate: false) == .remote)
    }

    @Test func ordinaryPublicAddressesAreRemote() {
        #expect(ConnectionClass.observed(peerAddress: "8.8.8.8", dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "1.1.1.1", dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "104.21.5.7", dialledRemoteCandidate: false) == .remote)
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
        #expect(ConnectionClass.observed(peerAddress: "100.64.0.1", dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "100.100.100.100", dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "100.127.255.255", dialledRemoteCandidate: false) == .remote)
    }

    // MARK: - IPv6

    @Test func ipv6LoopbackIsLocal() {
        #expect(ConnectionClass.observed(peerAddress: "::1", dialledRemoteCandidate: false) == .local)
    }

    @Test func theUnspecifiedIPv6AddressIsNotLocal() {
        // `::` is "no address", not "my address" — one bit away from ::1 and not a peer at all.
        #expect(ConnectionClass.observed(peerAddress: "::", dialledRemoteCandidate: false) == .remote)
    }

    @Test func ipv6UniqueLocalAddressesAreLocal() {
        // fc00::/7 covers both fc00::/8 and fd00::/8; fd is what real deployments use.
        #expect(ConnectionClass.observed(peerAddress: "fc00::1", dialledRemoteCandidate: false) == .local)
        #expect(ConnectionClass.observed(peerAddress: "fd12:3456:789a::1", dialledRemoteCandidate: false) == .local)
        #expect(ConnectionClass.observed(peerAddress: "fdff:ffff:ffff:ffff::1", dialledRemoteCandidate: false) == .local)
    }

    @Test func ipv6LinkLocalIsLocalIncludingWithAZoneSuffix() {
        #expect(ConnectionClass.observed(peerAddress: "fe80::1", dialledRemoteCandidate: false) == .local)
        // Network.framework reports link-local addresses with the interface zone attached; the
        // classifier must not choke on it and fail closed on a genuinely local connection.
        #expect(ConnectionClass.observed(peerAddress: "fe80::1cb2:3f4d:5e6f:7a8b%en0", dialledRemoteCandidate: false) == .local)
        // fe80::/10 ends at febf; fec0:: is (deprecated) site-local, outside the range.
        #expect(ConnectionClass.observed(peerAddress: "febf::1", dialledRemoteCandidate: false) == .local)
        #expect(ConnectionClass.observed(peerAddress: "fec0::1", dialledRemoteCandidate: false) == .remote)
    }

    /// A globally-routable IPv6 address is `.remote` **even if the host is physically on the LAN**.
    ///
    /// This is the accepted cost of the fail-closed rule, not an oversight: a GUA handed out by
    /// SLAAC is indistinguishable, from the address alone, from a host on the internet. Such a
    /// setup never auto-learns its remote URL and the user types one instead. The reverse mistake
    /// — treating an internet peer as local — adopts an attacker's URL permanently.
    @Test func publicIPv6IsRemote() {
        #expect(ConnectionClass.observed(peerAddress: "2001:4860:4860::8888", dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "2600:1901::1", dialledRemoteCandidate: false) == .remote)
    }

    @Test func ipv4MappedIPv6IsJudgedOnTheEmbeddedIPv4Address() {
        // ::ffff:a.b.c.d carries real IPv4 traffic. Judging the wrapper instead of the payload
        // would make ::ffff:8.8.8.8 and ::ffff:192.168.1.1 indistinguishable — both merely "not
        // fc00::/7" — and quietly classify Google's DNS the same as the user's router.
        #expect(ConnectionClass.observed(peerAddress: "::ffff:192.168.1.10", dialledRemoteCandidate: false) == .local)
        #expect(ConnectionClass.observed(peerAddress: "::ffff:10.0.0.5", dialledRemoteCandidate: false) == .local)
        #expect(ConnectionClass.observed(peerAddress: "::ffff:8.8.8.8", dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "::ffff:100.64.0.1", dialledRemoteCandidate: false) == .remote)
    }

    // MARK: - Fail closed

    @Test func anUnavailableAddressFailsClosedToRemote() {
        // The whole point of the fail-closed rule: "we could not tell" must never mean "trusted".
        #expect(ConnectionClass.observed(peerAddress: nil, dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "", dialledRemoteCandidate: false) == .remote)
    }

    @Test func garbageAndUnresolvedHostnamesFailClosedToRemote() {
        #expect(ConnectionClass.observed(peerAddress: "banana", dialledRemoteCandidate: false) == .remote)
        // A hostname is not an address, however local it looks. This is the exact confusion the
        // removed `ConnectionEndpoint.connectionClass` embodied.
        #expect(ConnectionClass.observed(peerAddress: "homeassistant.local", dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "192.168.1", dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "192.168.1.1.1", dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "192.168.1.256", dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "192.168.-1.1", dialledRemoteCandidate: false) == .remote)
    }

    /// `IPv4Address(String)` inherits `inet_aton`'s leniency — it reads `"10.1"` as `10.0.0.1` and
    /// `"0xc0a80101"` as `192.168.1.1` (both verified against the framework). Every one of those
    /// alternative spellings can only ever *widen* the private ranges, on a value that decides
    /// whether a connection is trusted, so the parser feeding this accepts dotted-quad and nothing
    /// else. If someone swaps it for `IPv4Address(_:)` "to simplify", these fail.
    @Test func shorthandAndHexIPv4SpellingsAreRejectedRatherThanExpandedIntoPrivateRanges() {
        #expect(ConnectionClass.observed(peerAddress: "10.1", dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "0xc0a80101", dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "0x7f000001", dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "2130706433", dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: " 10.0.0.1", dialledRemoteCandidate: false) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "10.0.0.1 ", dialledRemoteCandidate: false) == .remote)
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
        #expect(ConnectionClass.observed(peerAddress: PeerEndpointAddress.address(of: named), dialledRemoteCandidate: false) == .remote)
    }

    @Test func aMissingOrNonHostPortEndpointYieldsNoAddress() {
        #expect(PeerEndpointAddress.address(of: nil) == nil)
        #expect(PeerEndpointAddress.address(of: .service(name: "ha", type: "_http._tcp", domain: "local", interface: nil)) == nil)
    }

    // MARK: - `onKnownHomeNetwork` — the SSID signal that closes the IPv6-GUA gap

    /// The IP signal alone is untouched: a private address is still `.local` whether or not the
    /// caller even knows about SSIDs, matched or not.
    @Test func privateAddressIsLocalRegardlessOfSSIDSignal() {
        #expect(ConnectionClass.observed(peerAddress: "192.168.1.10", onKnownHomeNetwork: false, dialledRemoteCandidate: false) == .local)
        #expect(ConnectionClass.observed(peerAddress: "192.168.1.10", onKnownHomeNetwork: nil, dialledRemoteCandidate: false) == .local)
    }

    /// This is the case the parameter exists for: a globally-routable IPv6 address — indistinguishable
    /// from an internet host by address alone — is `.local` once the current Wi-Fi is known to match
    /// the user's configured home network.
    @Test func publicGUAWithMatchingSSIDIsLocal() {
        #expect(ConnectionClass.observed(peerAddress: "2600:1901::1", onKnownHomeNetwork: true, dialledRemoteCandidate: false) == .local)
    }

    @Test func publicGUAWithNoSSIDMatchIsStillRemote() {
        #expect(ConnectionClass.observed(peerAddress: "2600:1901::1", onKnownHomeNetwork: false, dialledRemoteCandidate: false) == .remote)
    }

    /// `nil` — SSID unknown, e.g. Location Services not authorized — must behave exactly like
    /// `false`, not like `true`. This is the fail-closed rule from `homeSSIDMatch` propagated all the
    /// way through, and it is what keeps this change from being a loosening for every user who never
    /// grants the permission — unchanged from Task 4's behaviour.
    @Test func publicGUAWithUnknownSSIDIsRemoteUnchangedFromBeforeThisSignalExisted() {
        #expect(ConnectionClass.observed(peerAddress: "2600:1901::1", onKnownHomeNetwork: nil, dialledRemoteCandidate: false) == .remote)
    }

    /// An unresolved/unavailable address is ambiguous in exactly the way a GUA is — it answers
    /// nothing — so the SSID is the only evidence left and is allowed to decide. It is still
    /// `.remote` without it (`aConnectionThatNeverBecameReadyReportsNoPeerAddressAndSoFailsClosed`).
    ///
    /// The comment this replaced called the two signals "a genuine OR, neither one gates the other".
    /// That was the bug review finding I-1 describes, written down as though it were the design —
    /// see `aDefinitivelyPublicPeerIsRemoteEvenOnTheMatchedHomeNetwork` below.
    @Test func unavailableAddressWithMatchingSSIDIsStillLocal() {
        #expect(ConnectionClass.observed(peerAddress: nil, onKnownHomeNetwork: true, dialledRemoteCandidate: false) == .local)
    }

    // MARK: - I-1: the SSID corroborates locality, it never establishes it
    //
    // A matching SSID proves "the phone is physically on the home network". It does NOT prove "this
    // connection stayed on the LAN" — you can be at home and still route out to the internet and
    // back. The original implementation consulted it first and unconditionally, so a connection with
    // a definitively public peer address was classified `.local` merely because the phone was home;
    // its `external_url`/`remote_domain` were then adopted and later handed to
    // `TokenProvider.setBaseURL`. That is the one thing design §1 forbids.

    @Test func aDefinitivelyPublicPeerIsRemoteEvenOnTheMatchedHomeNetwork() {
        // The test finding I-1 says was missing. A public IPv4 answers the question by itself — no
        // LAN hands one out — so the SSID gets no vote.
        #expect(ConnectionClass.observed(peerAddress: "203.0.113.7", onKnownHomeNetwork: true, dialledRemoteCandidate: false) == .remote)
        // Same for CGNAT (100.64/10), which is where a Tailscale peer lands and which this type
        // deliberately treats as remote.
        #expect(ConnectionClass.observed(peerAddress: "100.100.1.1", onKnownHomeNetwork: true, dialledRemoteCandidate: false) == .remote)
        // And for a hostname that was never resolved to an IP — nothing was observed, so there is
        // nothing for the SSID to corroborate… except that this case is genuinely ambiguous rather
        // than definitively public, which is why it stays `.local`. Pinned so the difference between
        // "the address says public" and "there is no address" is deliberate, not accidental.
        #expect(ConnectionClass.observed(peerAddress: "not-an-ip", onKnownHomeNetwork: true, dialledRemoteCandidate: false) == .local)
    }

    @Test func aCandidateDialledFromARemoteSlotIsRemoteWhateverElseSays() {
        // The concrete sequence from I-1: at home on the matched SSID, the local candidate fails
        // this round, the list falls through to the custom remote URL, and that connects. Whatever
        // its peer address turns out to be, we chose to go out to the internet — so nothing it
        // reports may be adopted.
        #expect(ConnectionClass.observed(peerAddress: "203.0.113.7", onKnownHomeNetwork: true, dialledRemoteCandidate: true) == .remote)
        // Including when the remote host resolves to something that *looks* private — a split-horizon
        // DNS answer, or a Nabu Casa tunnel terminated by something on the LAN. We know which slot we
        // dialled; that is not an inference from the address or the hostname.
        #expect(ConnectionClass.observed(peerAddress: "192.168.1.10", onKnownHomeNetwork: true, dialledRemoteCandidate: true) == .remote)
        #expect(ConnectionClass.observed(peerAddress: "2600:1901::1", onKnownHomeNetwork: true, dialledRemoteCandidate: true) == .remote)
        #expect(ConnectionClass.observed(peerAddress: nil, onKnownHomeNetwork: true, dialledRemoteCandidate: true) == .remote)
    }

    @Test func theGUACaseTheSSIDSignalExistsForStillWorks() {
        // Guard against over-correcting: the local-role candidate whose peer is a globally-routable
        // IPv6 on the LAN is still `.local` on a matched SSID, which is the entire reason the signal
        // was added. Only the *definitive* address cases stopped consulting it.
        #expect(ConnectionClass.observed(peerAddress: "2600:1901::1", onKnownHomeNetwork: true, dialledRemoteCandidate: false) == .local)
        #expect(ConnectionClass.observed(peerAddress: "fd00::1", onKnownHomeNetwork: nil, dialledRemoteCandidate: false) == .local)
    }
}
