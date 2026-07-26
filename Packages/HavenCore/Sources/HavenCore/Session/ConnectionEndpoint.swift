import Foundation

/// One candidate address for reaching a single Home Assistant instance — either its local (LAN)
/// address, or a remote one reachable from anywhere. Per HavenApp's product spec the remote
/// address is the user's *own* Nabu Casa (Home Assistant Cloud) `https://<uuid>.ui.nabu.casa`
/// URL, or a self-hosted reverse proxy — there is no Haven-operated relay.
///
/// This type is pure, sync value logic with no networking of its own: `AppModel` turns a
/// candidate's `url` into a `wss`/`ws` address via `HAConfig(baseURL:).webSocketURL` only when
/// it actually dials out.
public enum ConnectionEndpoint: Sendable, Equatable {
    case local(URL)
    case remote(URL)

    public var url: URL {
        switch self {
        case .local(let url), .remote(let url): return url
        }
    }

    public var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }

    // NOTE — there is deliberately **no** `connectionClass` property here, and adding one back
    // would be a security regression. It existed briefly as `isRemote ? .remote : .local` and was
    // passed to `DiscoveredCandidateURLs.validating` as `learnedOver`, which made this type's
    // *hostname-based bucketing* a trust input: `isRemote` is true only for `*.ui.nabu.casa`, so a
    // user-entered Tailscale address or reverse proxy (`https://ha.example.com`) landed in `.local`
    // and `get_config`'s URLs would have been adopted over a connection that crossed the internet.
    // The classification this type performs is for *ordering and scheme forcing* only — "which
    // bucket does this URL belong in" — and it is not evidence about the network a socket actually
    // travelled over. The only thing that is: `ConnectionClass.observed(peerAddress:)`, over the
    // address read off the live connection. Use that.

    /// Builds the ordered list of candidates to try for one connection attempt, from whatever
    /// URLs are known for this instance.
    ///
    /// - Parameters:
    ///   - userEntered: The URL the user typed (or restored from a previous sign-in). Usually
    ///     the LAN address, but classified remote if it happens to be a `*.ui.nabu.casa` host —
    ///     e.g. a user who signed in directly against their Nabu Casa URL.
    ///   - discoveredInternal: Home Assistant's own `internal_url` from `get_config`, if learned
    ///     from a previous successful connection. **The caller must have obtained this from
    ///     `DiscoveredCandidateURLs.validating` — i.e. it must have been learned over a `.local`
    ///     connection.** This function performs no trust check of its own; it only orders and
    ///     classifies what it is handed.
    ///   - discoveredExternal: Home Assistant's own `external_url` from `get_config`, under
    ///     exactly the same requirement: learned over a `.local` connection and adopted by
    ///     `DiscoveredCandidateURLs.validating`. Note what does *not* qualify a value for this
    ///     parameter — `isNabuCasaHost` below is a classification predicate and never establishes
    ///     that a URL belongs to this user (see its documentation, and the C-1 incident it
    ///     records).
    ///   - preferredFirst: A previously-successful URL to hoist to the front of the list, ahead
    ///     of the default local-before-remote ordering. Pass `nil` to always get the default
    ///     ordering (e.g. to re-probe the local candidate first).
    ///
    /// Rules:
    /// - Local candidates are tried before remote ones by default — local is faster and keeps
    ///   traffic off the internet.
    /// - A `*.ui.nabu.casa` host is always classified remote, regardless of which parameter
    ///   supplied it.
    /// - Every remote candidate's scheme is normalized to `https` (so `HAConfig.webSocketURL`
    ///   derives `wss`), even if the caller supplied `http`.
    /// - The result never contains duplicate candidates (compared by scheme+host+port).
    /// - The result is never empty as long as at least one input URL is non-nil.
    public static func candidates(
        userEntered: URL?,
        discoveredInternal: URL?,
        discoveredExternal: URL?,
        preferredFirst: URL? = nil
    ) -> [ConnectionEndpoint] {
        var seenKeys: Set<String> = []
        var endpoints: [ConnectionEndpoint] = []

        func append(_ url: URL?, defaultLocal: Bool) {
            guard let url else { return }
            let endpoint = classify(url, defaultLocal: defaultLocal)
            let key = normalizedKey(endpoint.url)
            guard !seenKeys.contains(key) else { return }
            seenKeys.insert(key)
            endpoints.append(endpoint)
        }

        // Local-leaning sources appended first, so the default order already prefers local over
        // remote without any further sorting needed for the common case.
        append(discoveredInternal, defaultLocal: true)
        append(userEntered, defaultLocal: true)
        append(discoveredExternal, defaultLocal: false)

        let locals = endpoints.filter { !$0.isRemote }
        let remotes = endpoints.filter(\.isRemote)
        var ordered = locals + remotes

        if let preferredFirst {
            let key = normalizedKey(preferredFirst)
            if let index = ordered.firstIndex(where: { normalizedKey($0.url) == key }) {
                let endpoint = ordered.remove(at: index)
                ordered.insert(endpoint, at: 0)
            }
        }
        return ordered
    }

    /// Answers exactly one question: **is this host *a* Nabu Casa host** — a suffix match on
    /// `.ui.nabu.casa` (so `abc123.ui.nabu.casa` matches, but a lookalike like
    /// `evil-ui.nabu.casa` or a host merely containing the string, e.g. `attacker.com` serving a
    /// path of `/.ui.nabu.casa`, does not: `URL.host` is just the authority's host component,
    /// never a path).
    ///
    /// **This is a category check, not an identity check, and must never be used as one.**
    /// `*.ui.nabu.casa` subdomains are issued to any paying Nabu Casa subscriber — including an
    /// attacker, who can legitimately obtain their own. A URL passing this check proves only that
    /// it is *some* Nabu Casa instance; it proves nothing about whether it is *this user's*
    /// instance. An earlier fix round used this predicate to decide whether a `get_config`-
    /// reported `external_url` was safe to auto-adopt as a future connection candidate (one that
    /// `TokenProvider` would later trust with the refresh token) — that was the bug: it let an
    /// attacker who MITM'd exactly one `get_config` response inject their own genuine, valid Nabu
    /// Casa host and have it trusted indefinitely afterwards. What decides adoption now is the
    /// *connection class* a URL was learned over, never its hostname — see
    /// `DiscoveredCandidateURLs`. This function is still correct and still needed for what it
    /// actually answers: *classifying* a URL the caller already has an independent reason to trust
    /// (one the user typed, or one learned over a local connection) as local vs. remote, so that
    /// every remote candidate gets its mandatory `https` — see `classify` below, its only caller.
    public static func isNabuCasaHost(_ url: URL) -> Bool {
        url.host?.lowercased().hasSuffix(".ui.nabu.casa") ?? false
    }

    private static func classify(_ url: URL, defaultLocal: Bool) -> ConnectionEndpoint {
        guard !isNabuCasaHost(url), defaultLocal else {
            return .remote(forcedHTTPS(url))
        }
        return .local(url)
    }

    private static func forcedHTTPS(_ url: URL) -> URL {
        guard url.scheme?.lowercased() != "https" else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = "https"
        return components.url ?? url
    }

    /// Module-internal rather than private so `ConnectionPreference` can hoist `lastWorking` on the
    /// exact same identity this function de-duplicates on, instead of maintaining a second notion
    /// of "the same endpoint" that could drift.
    static func normalizedKey(_ url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let scheme = (components?.scheme ?? url.scheme ?? "").lowercased()
        let host = (components?.host ?? url.host ?? "").lowercased()
        let port = components?.port ?? url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}
