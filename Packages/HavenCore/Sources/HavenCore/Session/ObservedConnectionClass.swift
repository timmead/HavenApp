import Foundation
import Network

extension ConnectionClass {
    /// Classifies a live connection by **the resolved address of the peer we are actually talking
    /// to** — the only thing that can answer "did this connection cross the internet?".
    ///
    /// ## Why not the hostname
    ///
    /// This replaces `ConnectionEndpoint.connectionClass`, which was `isRemote ? .remote : .local`
    /// and whose `isRemote` was true only for `*.ui.nabu.casa`. Because
    /// `DiscoveredCandidateURLs.validating` is keyed on the connection class, that made the
    /// hostname a **trust input**: a user-entered Tailscale address or reverse proxy
    /// (`https://ha.example.com`) classified `.local`, so `get_config`'s URLs — including a new
    /// `external_url` that `TokenProvider` would later POST the refresh token to — would have been
    /// adopted over a connection that in fact crossed the internet. That voids the one rule the
    /// whole design rests on (see `docs/superpowers/specs/2026-07-26-havenapp-connection-model-design.md`
    /// §1). The old property is **deleted**, not deprecated, so it cannot be picked up again.
    ///
    /// A hostname cannot answer "is this on my LAN", and on a hostile network neither can DNS — the
    /// resolver is whatever the network says it is. The socket can: once the connection is `.ready`,
    /// the kernel knows which address the bytes are going to, and no amount of DNS or `get_config`
    /// lying changes it.
    ///
    /// ## The rule
    ///
    /// `.local` **iff** the peer address is loopback, link-local, or private:
    /// IPv4 `127/8`, `10/8`, `172.16/12`, `192.168/16`, `169.254/16`; IPv6 `::1`, `fc00::/7` (ULA),
    /// `fe80::/10` (link-local), plus IPv4-mapped forms (`::ffff:a.b.c.d`) judged on the embedded
    /// IPv4 address. Everything else — **including CGNAT `100.64/10`, which is where a Tailscale
    /// peer lands** — is `.remote`.
    ///
    /// **Anything unclassifiable fails closed to `.remote`**: a `nil` address (the endpoint was
    /// never resolved to an IP, or the transport can't report one), a malformed string, anything
    /// that isn't a valid IP literal. The two mistakes are not symmetrical. Classifying a genuinely
    /// local connection as remote costs us a URL we don't auto-learn — the user types their remote
    /// address by hand. Classifying a genuinely remote connection as local adopts an attacker's URL
    /// as a permanent, token-receiving candidate. So every uncertainty resolves the first way.
    ///
    /// **The IPv6-GUA gap, and the second signal that closes it.** A home whose Home Assistant is
    /// reached over a *globally routable* IPv6 address (a GUA from SLAAC, rather than a ULA or
    /// link-local) cannot be told apart from a host on the internet **by address alone** — a growing
    /// number of consumer routers hand these out on the LAN. The IP check above therefore classifies
    /// that connection `.remote` even while the phone is sitting in the house. `onKnownHomeNetwork`
    /// is how the caller supplies the other fact that resolves it: `ConnectionPreference.homeSSIDMatch`,
    /// the same "is the current Wi-Fi the one I called home" comparison layer 1 already uses for
    /// candidate *ordering* — reused here, not recomputed, so there is exactly one place that decides
    /// what "home" means.
    ///
    /// **This is not a loosening of the trust rule, it is the same rule read correctly.** The
    /// existing IP check already trusts *any* private address as "the local network" — which really
    /// means "whatever network handed out that private address", rogue access point included. A
    /// matching SSID is exactly as spoofable as that, no more and no less; it is not a weaker signal
    /// bolted onto a strong one, it is a second way to observe the same thing the IP check observes.
    /// Both still describe *where a fact was learned*, which is what §1 requires — neither says
    /// anything about *what* the fact says.
    ///
    /// - Parameters:
    ///   - peerAddress: The peer's resolved IP literal, e.g. from
    ///     `NWWebSocketConnection.observedPeerAddress`. An IPv6 zone suffix (`fe80::1%en0`) is fine.
    ///   - onKnownHomeNetwork: Whether the current Wi-Fi is known to match the user's configured home
    ///     network — `ConnectionPreference.homeSSIDMatch(current:home:)`. `nil` and `false` are
    ///     treated identically: **"unknown" must never be read as "home"**, the same fail-closed
    ///     posture as an unresolved address below. Defaulted to `nil` so every existing call site
    ///     (all of §1–§4's IP-only tests) keeps its original meaning unchanged.
    public static func observed(peerAddress: String?, onKnownHomeNetwork: Bool? = nil) -> ConnectionClass {
        if onKnownHomeNetwork == true { return .local }

        guard let peerAddress, !peerAddress.isEmpty else { return .remote }

        if let octets = strictIPv4Octets(peerAddress) {
            return isPrivateIPv4(octets) ? .local : .remote
        }
        if let v6 = IPv6Address(peerAddress) {
            return isPrivateIPv6(Array(v6.rawValue)) ? .local : .remote
        }
        // Not a parseable IP literal at all — a hostname that was never resolved, or garbage.
        return .remote
    }

    /// Strict dotted-quad parsing, deliberately hand-rolled rather than using `IPv4Address(String)`.
    ///
    /// `IPv4Address` inherits `inet_aton`'s historical leniency: it accepts `"10.1"` as `10.0.0.1`
    /// and `"0x7f000001"` as `127.0.0.1` (both verified). Those forms can only ever *widen* what
    /// counts as private, and this value decides whether a connection is trusted, so the parser
    /// that feeds it accepts exactly one spelling and nothing else.
    private static func strictIPv4Octets(_ string: String) -> [UInt8]? {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        octets.reserveCapacity(4)
        for part in parts {
            // Rejects "", "+1", " 1", "01" is allowed by UInt8() but harmless; what matters is that
            // nothing non-decimal and nothing out of 0...255 gets through.
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let value = UInt8(part) else { return nil }
            octets.append(value)
        }
        return octets
    }

    private static func isPrivateIPv4(_ o: [UInt8]) -> Bool {
        switch (o[0], o[1]) {
        case (127, _):              return true   // 127/8      loopback
        case (10, _):               return true   // 10/8       RFC1918
        case (172, 16...31):        return true   // 172.16/12  RFC1918
        case (192, 168):            return true   // 192.168/16 RFC1918
        case (169, 254):            return true   // 169.254/16 link-local
        default:                    return false  // incl. 100.64/10 CGNAT — see the type doc
        }
    }

    private static func isPrivateIPv6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        // IPv4-mapped (::ffff:a.b.c.d) — judge the address that actually carries the traffic, not
        // the wrapper, or `::ffff:8.8.8.8` would fall through to "not fc00::/7" and look the same
        // as `::ffff:192.168.1.1`.
        if b[0...9].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {
            return isPrivateIPv4(Array(b[12...15]))
        }
        // ::1 — loopback. (:: — the unspecified address — is deliberately NOT local.)
        if b[0...14].allSatisfy({ $0 == 0 }), b[15] == 1 { return true }
        // fc00::/7 — unique local addresses.
        if b[0] & 0xfe == 0xfc { return true }
        // fe80::/10 — link-local.
        if b[0] == 0xfe, b[1] & 0xc0 == 0x80 { return true }
        return false
    }
}
