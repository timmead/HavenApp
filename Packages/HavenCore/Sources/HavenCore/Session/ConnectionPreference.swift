import Foundation

/// What kind of network interface the device is currently using, as reported by `NWPathMonitor`.
///
/// **Read what this does and does not tell you.** It distinguishes **Wi-Fi from cellular**. It does
/// *not* distinguish **home Wi-Fi from a café's** — nothing in `NWPath` can. `.wifi` therefore means
/// "a LAN address is worth probing", never "we are home". The layer that can tell home from
/// elsewhere is the SSID match, and it is optional (see `ConnectionPreference`).
public enum NetworkPathClass: Sendable, Equatable {
    /// Wi-Fi — could be home, could be anywhere.
    case wifi
    /// Cellular. A LAN address cannot work here.
    case cellular
    /// Wired, or no path/unknown. Treated like Wi-Fi: worth probing local.
    case other
}

/// Decides **the order in which connection candidates are tried**, from whatever the app currently
/// knows about where it is.
///
/// ## Three layers, each a fallback for the one above — none of them required
///
/// This is a graceful-degradation stack, not a set of alternatives. Every layer only ever changes
/// *ordering*, never which candidates exist, so the app is **fully correct with every layer
/// unavailable** — it just pays a probe it could have skipped.
///
/// 1. **Wi-Fi SSID match** (`homeSSIDMatch`) — the only layer that actually knows "am I home".
///    Optional and opt-in: reading the current SSID needs Location Services authorization, which is
///    offered later in settings as "connect faster at home", **never as an onboarding gate**. A
///    permission prompt during first-run costs more than the latency it saves, and sits badly
///    beside a local-first, privacy-led product. `nil` means unknown — not permitted, not yet
///    captured, or simply not asked — and must behave exactly like the permission having been
///    denied.
/// 2. **Network path class** (`pathClass`) — free, no permissions. Only rules out the case it can
///    actually rule out: on cellular, a LAN address will not answer.
/// 3. **Fast local probe** — the universal fallback, and the reason no layer is required. Try
///    local, fail over to remote. `NWWebSocketConnection`'s deadline (2s) is what makes this cheap
///    enough to be the default.
///
/// ## Why this is a pure function and not a method on `AppModel`
///
/// `App/` has **no test target**, so ordering logic placed there is a claim about behaviour nobody
/// exercises — which is how two bugs shipped green. Every branch below is unit-tested in
/// `ConnectionPreferenceTests`. `AppModel` supplies the three inputs (SSID match, path class,
/// stored URLs) and does nothing else.
public enum ConnectionPreference {

    /// Whether the network we are on is the one we last connected to Home Assistant locally over.
    ///
    /// - Returns: `nil` — meaning **unknown, treat as no signal** — whenever either side is
    ///   missing. `nil` is the normal state, not an edge case: it covers Location Services not
    ///   authorized, a device that has never yet had a successful local connection, and cellular.
    ///
    /// Compared case-insensitively. SSIDs are byte strings and two APs can legitimately differ in
    /// case; a case-sensitive miss here would silently downgrade a user who *did* grant permission
    /// back to layer 3, which is the failure mode this layer exists to avoid.
    public static func homeSSIDMatch(current: String?, home: String?) -> Bool? {
        guard let current, !current.isEmpty, let home, !home.isEmpty else { return nil }
        return current.compare(home, options: .caseInsensitive) == .orderedSame
    }

    /// Which class of candidate to try **first**, given the two optional signals.
    ///
    /// - `homeSSIDMatch == true` → `.local`. We are on the home network; the LAN address is both
    ///   faster and keeps the traffic off the internet.
    /// - `homeSSIDMatch == false` → `.remote`. We know we are *not* home, so the local probe is
    ///   known-doomed. (Layer 1 is the only input that can establish this.)
    /// - unknown + `.cellular` → `.remote`. A LAN address cannot be reached over cellular.
    /// - unknown + `.wifi`/`.other` → `.local`. Might be home, might be a café — see
    ///   `NetworkPathClass`. Local first, then fail over.
    public static func leadingClass(homeSSIDMatch: Bool?, pathClass: NetworkPathClass) -> ConnectionClass {
        if let homeSSIDMatch { return homeSSIDMatch ? .local : .remote }
        return pathClass == .cellular ? .remote : .local
    }

    /// The ordered candidate list for one connection round.
    ///
    /// Composes over `ConnectionEndpoint.candidates` rather than reimplementing it: that function
    /// still owns *which* candidates exist, their local/remote bucketing, `https` forcing for
    /// remotes and de-duplication. This function owns **order only**.
    ///
    /// - Parameters:
    ///   - lastWorking: The URL that last completed a full connect, hoisted to the front — but
    ///     **only when it is in the leading class**. Hoisting unconditionally would let a stale
    ///     success undo the layer decision entirely: the user's last connect was at home over the
    ///     LAN, so `lastWorking` is the local URL, and hoisting it on cellular reintroduces exactly
    ///     the doomed local probe layer 2 just removed. Restricting the hoist to the leading class
    ///     keeps it doing its actual job — choosing *among* several candidates of the same kind —
    ///     without letting it outrank a live signal about where the phone is.
    ///   - customRemote: the user's own externally-reachable URL, if they set one. **Required, not
    ///     defaulted** — unlike `ConnectionEndpoint.candidates`'s parameter of the same name. This
    ///     is the function `AppModel.connect()` calls, and the dominant failure mode for a feature
    ///     like this is a perfectly tested HavenCore function that the one real caller never passes
    ///     anything to: green tests, and the URL the user typed is never dialled. A required
    ///     parameter makes that a compile error instead.
    ///   - homeSSIDMatch: layer 1, `nil` when unknown/not permitted. See `homeSSIDMatch(current:home:)`.
    ///   - pathClass: layer 2.
    ///
    /// **Candidates are reordered, never dropped** — including on cellular, where a local candidate
    /// cannot possibly answer. Two reasons. `ConnectionEndpoint.candidates` buckets any
    /// non-Nabu-Casa *user-entered* URL as local, so someone who signed in directly against their
    /// Tailscale or reverse-proxy address — the one that does work off-LAN — has it sitting in the
    /// "local" bucket, and dropping locals would strip their only working candidate the moment they
    /// also have a Nabu Casa URL. (The `customRemote` slot below is the supported way to hold such
    /// an address, and it *is* bucketed remote — but the sign-in URL is not, and both exist.) And
    /// dropping breaks the invariant that the list is never empty while any input URL is non-nil,
    /// which is what stops a mis-signalled path class from turning into "the app cannot connect at
    /// all". The 2s connect deadline is what makes carrying a doomed candidate at the back of the
    /// list cheap enough that ordering alone is sufficient.
    public static func candidates(
        userEntered: URL?,
        discoveredInternal: URL?,
        discoveredExternal: URL?,
        customRemote: URL?,
        lastWorking: URL? = nil,
        homeSSIDMatch: Bool?,
        pathClass: NetworkPathClass
    ) -> [ConnectionEndpoint] {
        // `preferredFirst: nil` — the hoist is applied here instead, gated on the leading class.
        let base = ConnectionEndpoint.candidates(
            userEntered: userEntered,
            discoveredInternal: discoveredInternal,
            discoveredExternal: discoveredExternal,
            customRemote: customRemote,
            preferredFirst: nil
        )
        let leading = leadingClass(homeSSIDMatch: homeSSIDMatch, pathClass: pathClass)

        // `base` is already local-first; only the remote-leading case needs re-partitioning. Both
        // branches are stable, so relative order within each bucket is preserved.
        var ordered = leading == .remote
            ? base.filter(\.isRemote) + base.filter { !$0.isRemote }
            : base

        // Matched on the *same* scheme+host+port key `ConnectionEndpoint.candidates` de-duplicates
        // on, rather than a second notion of "same URL" that could drift out of step with it.
        // `lastWorking` is written from an already-normalized candidate URL, so the key matches;
        // a value that fails to match simply doesn't hoist, which costs nothing.
        if let lastWorking {
            let key = ConnectionEndpoint.normalizedKey(lastWorking)
            if let index = ordered.firstIndex(where: {
                endpointClass($0) == leading && ConnectionEndpoint.normalizedKey($0.url) == key
            }) {
                ordered.insert(ordered.remove(at: index), at: 0)
            }
        }
        return ordered
    }

    private static func endpointClass(_ endpoint: ConnectionEndpoint) -> ConnectionClass {
        endpoint.isRemote ? .remote : .local
    }
}
