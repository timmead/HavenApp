import Foundation

/// Thrown by `TokenProvider` when the stored session can no longer produce a usable access
/// token and the only remaining option is to send the user back through sign-in.
public enum TokenProviderError: Error, Sendable, Equatable {
    case reauthenticationRequired
    /// A refresh that was in flight when `invalidate()` was called. The caller should treat this
    /// the same as any other non-terminal failure — by the time it surfaces, whatever owned this
    /// `TokenProvider` has already moved on (signed out, or replaced it with a fresh instance for
    /// a new session) and should ignore the result.
    case invalidated

    /// iOS App Transport Security refused the refresh POST outright:
    /// `URLError.appTransportSecurityRequiresSecureConnection` (-1022). The session is fine; the
    /// **address** is not — a cleartext `http://` URL whose hostname ATS judges to be a public host.
    ///
    /// ## Why this needs a case of its own rather than falling through as a network error
    ///
    /// It is deterministic and configuration-caused: every retry against that address produces it
    /// again, for as long as the app is installed. Left unclassified it arrives at `AppModel` as an
    /// opaque `URLError`, is handled by the same generic `catch` as "Wi-Fi dropped", and feeds the
    /// unbounded retry loop — so the user sees "connecting…" forever, with nothing anywhere naming
    /// ATS. Worse, the trigger is a *token expiry hours later*: the app works fine right up until
    /// the first refresh, so nothing in testing that immediately follows a change would ever show
    /// it. That is this project's recurring failure shape — a wrong assumption producing a
    /// confident wrong state instead of an error — and the fix for it is always the same: name it.
    ///
    /// **The stored tokens are deliberately not cleared.** Unlike `reauthenticationRequired`, the
    /// grant is untouched — signing the user out would destroy a perfectly good session over a URL
    /// they can simply edit. It is also only terminal for *this address*: `AppModel` tries other
    /// candidates first (a private-IP LAN address is allowed by `NSAllowsLocalNetworking` and will
    /// still refresh normally), and only stops when every candidate in a round was blocked this way.
    ///
    /// See the ATS comment in `App/Resources/Info.plist` for what is and isn't covered, and why the
    /// remedy is a narrow exception rather than re-enabling arbitrary loads.
    case insecureTransportBlocked(host: String)

    /// Whether retrying can ever help.
    ///
    /// `invalidated` is neither — it means "this result belongs to a session that has already been
    /// replaced; ignore it" — so it answers `false` and the caller's ordinary "ignore and move on"
    /// path is correct for it.
    public var isTerminal: Bool {
        switch self {
        case .reauthenticationRequired, .insecureTransportBlocked: return true
        case .invalidated: return false
        }
    }

    /// Copy to show the user, for the cases where there is something they can actually do. `nil`
    /// where there isn't: `reauthenticationRequired` already routes to the sign-in screen, and
    /// `invalidated` is never user-visible.
    ///
    /// Lives here rather than in `App/` for the usual reason — the message *is* the fix for
    /// `insecureTransportBlocked` (a silent hang made into a named failure), and `App/` has no test
    /// target. It names the address, the rule that refused it, and both ways out.
    public var message: String? {
        switch self {
        case .reauthenticationRequired, .invalidated:
            return nil
        case .insecureTransportBlocked(let host):
            return """
            iOS blocked Haven from reaching \(host): the address is http://, and \(host) isn't \
            recognised as a local network address, so the connection can't be unencrypted. Change \
            the address above to https://\(host) if your Home Assistant serves it, or to its \
            local network address — something like http://192.168.1.10:8123.
            """
        }
    }
}

/// The single place that answers "give me a valid access token" for a Home Assistant instance.
///
/// Returns the cached access token while it is still fresh, and transparently refreshes it
/// (persisting the result via `TokenStore`) when it has expired or is about to. Concurrent
/// callers that arrive while a refresh is already underway are coalesced onto that one
/// in-flight attempt rather than each triggering their own network round trip.
public actor TokenProvider {
    /// The host the refresh-token HTTP POST (`{baseURL}/auth/token`) targets. `var`, not `let`:
    /// a single Home Assistant instance is reachable at more than one address (local vs.
    /// remote/Nabu Casa), and refreshing must go to whichever one the caller is currently trying
    /// — see `setBaseURL(_:)`.
    private var baseURL: URL
    private let store: TokenStore
    private let oauth: OAuthClient
    private let http: HTTPPoster
    /// How far ahead of the real expiry we treat a token as already expired, so a token never
    /// expires mid-request.
    private let skew: TimeInterval

    /// A single in-flight refresh shared by every caller that arrives while it is running.
    private var refreshTask: Task<String, Error>?
    /// Bumped by `invalidate()`. A refresh started before the bump must not persist its result
    /// after it — this instance may be a stale holdover (e.g. the app signed out, or signed back
    /// in against a different host, while this refresh was still awaiting the network) that
    /// shares its `TokenStore` with whatever replaced it.
    private var generation = 0

    public init(baseURL: URL, store: TokenStore, oauth: OAuthClient, http: HTTPPoster, skew: TimeInterval = 60) {
        self.baseURL = baseURL
        self.store = store
        self.oauth = oauth
        self.http = http
        self.skew = skew
    }

    /// Repoints this provider at a different address for the *same* Home Assistant instance —
    /// e.g. `AppModel`'s candidate failover switching from the local URL to the remote/Nabu Casa
    /// one. Call this before `validAccessToken`/`forceRefresh` for whichever candidate is about
    /// to be tried, so a refresh triggered from here on posts to the right host. (Doesn't affect
    /// a refresh that's already in flight when it's called — see `refreshTask` coalescing above.)
    public func setBaseURL(_ url: URL) {
        baseURL = url
    }

    public func validAccessToken(now: Date) async throws -> String {
        // Coalesce: if a refresh is already underway, ride it instead of starting another.
        if let inFlight = refreshTask {
            return try await inFlight.value
        }

        guard let tokens = store.load() else {
            throw TokenProviderError.reauthenticationRequired
        }

        if tokens.expiresAt.timeIntervalSince(now) > skew {
            return tokens.accessToken
        }

        guard let refreshToken = tokens.refreshToken else {
            throw TokenProviderError.reauthenticationRequired
        }

        return try await refresh(refreshToken: refreshToken)
    }

    /// Forces a refresh even though the cached token isn't (by our clock) expired yet.
    ///
    /// Used when Home Assistant rejects a token outright that `validAccessToken` had just vouched
    /// for — e.g. it was revoked out of band, or there's clock skew between the device and the
    /// server — so a single forced refresh can recover the session without bouncing the user to
    /// sign-in for what may be a transient/local-clock issue.
    public func forceRefresh() async throws -> String {
        if let inFlight = refreshTask {
            return try await inFlight.value
        }
        guard let refreshToken = store.load()?.refreshToken else {
            throw TokenProviderError.reauthenticationRequired
        }
        return try await refresh(refreshToken: refreshToken)
    }

    /// Abandons any in-flight refresh and prevents it from writing to the store when it
    /// eventually completes. Call this before dropping a `TokenProvider` (sign-out, or replacing
    /// it with a fresh instance for a new session) — otherwise a refresh that was already
    /// in-flight can complete afterwards and overwrite whatever the store holds by then, since the
    /// old and new `TokenProvider` share the same `TokenStore`/Keychain entry. Cancelling the
    /// `Task` alone isn't sufficient (cancellation of the underlying network call isn't always
    /// prompt), so this also bumps a generation counter the in-flight refresh checks before it
    /// persists anything.
    public func invalidate() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func refresh(refreshToken: String) async throws -> String {
        let myGeneration = generation
        let task = Task<String, Error> {
            do {
                let refreshed = try await self.oauth.refresh(baseURL: self.baseURL, refreshToken: refreshToken, http: self.http)
                guard self.generation == myGeneration else {
                    // Invalidated while this refresh was in flight — the store may already belong
                    // to a different session by now. Do not touch it.
                    throw TokenProviderError.invalidated
                }
                try self.store.save(refreshed)
                return refreshed.accessToken
            } catch let wsError as WSError where wsError.isInvalidGrant {
                guard self.generation == myGeneration else {
                    throw TokenProviderError.invalidated
                }
                // The refresh token itself was rejected — no amount of retrying will help;
                // the user must sign in again.
                self.store.clear()
                throw TokenProviderError.reauthenticationRequired
            } catch let urlError as URLError where urlError.code == .appTransportSecurityRequiresSecureConnection {
                guard self.generation == myGeneration else {
                    throw TokenProviderError.invalidated
                }
                // Named rather than left to escape as an opaque `URLError`, which the caller's
                // generic network-failure path would retry forever. The store is deliberately
                // untouched — the grant is fine, the address isn't. See the case's documentation.
                throw TokenProviderError.insecureTransportBlocked(host: self.baseURL.host() ?? self.baseURL.absoluteString)
            }
        }
        refreshTask = task
        defer {
            // Only clear it if we're still the current generation — if `invalidate()` ran while
            // we were suspended below, a newer refresh may have already taken `refreshTask`'s
            // place, and this (now-stale) `defer` must not clobber it.
            if generation == myGeneration { refreshTask = nil }
        }
        return try await task.value
    }
}
