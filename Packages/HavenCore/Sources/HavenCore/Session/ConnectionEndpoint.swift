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

    /// Builds the ordered list of candidates to try for one connection attempt, from whatever
    /// URLs are known for this instance.
    ///
    /// - Parameters:
    ///   - userEntered: The URL the user typed (or restored from a previous sign-in). Usually
    ///     the LAN address, but classified remote if it happens to be a `*.ui.nabu.casa` host —
    ///     e.g. a user who signed in directly against their Nabu Casa URL.
    ///   - discoveredInternal: Home Assistant's own `internal_url` from `get_config`, if learned
    ///     from a previous successful connection.
    ///   - discoveredExternal: Home Assistant's own `external_url` from `get_config`. For a Nabu
    ///     Casa subscriber this is the `*.ui.nabu.casa` URL once cloud remote access is enabled.
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

    private static func classify(_ url: URL, defaultLocal: Bool) -> ConnectionEndpoint {
        let isNabuCasa = url.host?.lowercased().hasSuffix(".ui.nabu.casa") ?? false
        guard !isNabuCasa, defaultLocal else {
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

    private static func normalizedKey(_ url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let scheme = (components?.scheme ?? url.scheme ?? "").lowercased()
        let host = (components?.host ?? url.host ?? "").lowercased()
        let port = components?.port ?? url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}
