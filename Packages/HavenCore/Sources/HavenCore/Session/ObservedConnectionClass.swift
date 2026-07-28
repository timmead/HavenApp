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
    /// **The SSID corroborates locality; it can never establish it on its own.** This is the
    /// correction to review finding I-1, and the distinction is the whole of it: a matching SSID
    /// proves *"the phone is physically on the home network"*. It does **not** prove *"this
    /// connection stayed on the LAN"* — you can be sitting at home and still route out to the
    /// internet and back. Consulting it first and unconditionally, as this function originally did,
    /// meant a connection with a definitively public peer address was classified `.local` merely
    /// because the phone was at home: the far end of a connection that crossed the internet could
    /// then nominate a new token-receiving host, which is precisely what §1 forbids. So the SSID is
    /// now reached only where the address evidence is genuinely *ambiguous* — an IPv6 GUA, or no
    /// usable address at all — which is the case it was introduced for, and never where the address
    /// answers the question by itself.
    ///
    /// **And a candidate we deliberately dialled as remote is remote, whatever else says otherwise.**
    /// `dialledRemoteCandidate` is our own record of which storage slot the URL came from — the Nabu
    /// Casa/discovered-external slot, or the user's custom remote URL — not an inference from the
    /// URL's *shape*. That distinction matters: this is **not** a return of the deleted
    /// `ConnectionEndpoint.connectionClass`, which guessed from the hostname (`*.ui.nabu.casa` ⇒
    /// remote, everything else ⇒ local) and so mislabelled a user's reverse proxy as local. Here the
    /// app is not guessing at all — it chose to go out to the internet, and it knows it did.
    ///
    /// - Parameters:
    ///   - peerAddress: The peer's resolved IP literal, e.g. from
    ///     `NWWebSocketConnection.observedPeerAddress`. An IPv6 zone suffix (`fe80::1%en0`) is fine.
    ///   - onKnownHomeNetwork: Whether the current Wi-Fi is known to match the user's configured home
    ///     network — `ConnectionPreference.homeSSIDMatch(current:home:)`. `nil` and `false` are
    ///     treated identically: **"unknown" must never be read as "home"**, the same fail-closed
    ///     posture as an unresolved address. Only consulted where the address cannot decide.
    ///   - dialledRemoteCandidate: Whether the candidate this connection was made to came from a
    ///     remote slot — `ConnectionEndpoint.isRemote` for the candidate `AppModel` actually dialled.
    ///     **Required, not defaulted:** the permissive value would be the wrong default for an input
    ///     that decides whether a self-reported URL may be adopted, and every call site should have
    ///     to say which kind of candidate it is describing.
    public static func observed(
        peerAddress: String?,
        onKnownHomeNetwork: Bool? = nil,
        dialledRemoteCandidate: Bool
    ) -> ConnectionClass {
        // We chose to dial a remote address. Nothing observed afterwards can make that connection
        // local, and no other signal gets a vote.
        if dialledRemoteCandidate { return .remote }

        if let peerAddress, !peerAddress.isEmpty {
            // The interface qualifier is stripped for the IPv4 parse and **only** for it.
            // `NWPath.remoteEndpoint` reports the interface a socket is bound to — `192.168.1.42%en0`
            // is a real observed value, from a device log — and `strictIPv4Octets` splits on `.`
            // and then fails on `"42%en0"`, so an unmistakably private LAN address fell through to
            // the fail-closed branch and every local connection was classified `.remote`.
            //
            // `IPv6Address` needs no such help: it accepts a zone identifier natively, which is why
            // the IPv6 side of this never broke (see `ipv6LinkLocalIsLocalIncludingWithAZoneSuffix`,
            // written at the time; the IPv4 equivalent simply never was). So the v6 branch below is
            // deliberately given the *original* string, zone and all — that is a spelling it
            // understands, and narrowing it here would be a change with no benefit to justify it.
            if let octets = strictIPv4Octets(withoutZoneIdentifier(peerAddress)) {
                // Definitive both ways: a LAN never hands out a public IPv4, so a public one here
                // means the bytes left the network — the SSID does not get to overrule it.
                return isPrivateIPv4(octets) ? .local : .remote
            }
            if let v6 = IPv6Address(peerAddress) {
                if isPrivateIPv6(Array(v6.rawValue)) { return .local }
                // The one genuinely ambiguous address, and the reason `onKnownHomeNetwork` exists: a
                // globally-routable IPv6 (SLAAC GUA) is what a growing number of consumer routers
                // hand out *on the LAN*, and it is indistinguishable from an internet host by
                // address alone.
                return onKnownHomeNetwork == true ? .local : .remote
            }
        }
        // No usable address: unresolved, unreportable, or not an IP literal at all. Ambiguous in the
        // same way, so the SSID is the only evidence left — and absent that, fail closed.
        return onKnownHomeNetwork == true ? .local : .remote
    }

    /// The address with any interface qualifier removed — `"192.168.1.42%en0"` → `"192.168.1.42"`.
    ///
    /// **This can only ever make a string parseable; it can never change which address is judged.**
    /// A zone identifier says which interface a link-scoped address is reachable on. It is not part
    /// of the address, carries none of its bits, and sits entirely after the `%`. So `8.8.8.8%en0`
    /// strips to `8.8.8.8` and stays public, and nothing that was `.remote` can become `.local` by
    /// way of this — which is the property `aZoneSuffixDoesNotMakeAPublicAddressLocal` exists to
    /// hold, including for the shorthand spellings the strict parser refuses.
    ///
    /// Taken up to the *first* `%`, so a string with several leaves the remainder in the parsed
    /// portion, where the strict parser rejects it. Deliberately applied at the call site rather
    /// than inside `strictIPv4Octets`: that function's contract is that it accepts exactly one
    /// spelling and nothing else, and it is worth keeping it that literal.
    private static func withoutZoneIdentifier(_ address: String) -> String {
        String(address.prefix { $0 != "%" })
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
