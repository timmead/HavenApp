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
}

/// The single place that answers "give me a valid access token" for a Home Assistant instance.
///
/// Returns the cached access token while it is still fresh, and transparently refreshes it
/// (persisting the result via `TokenStore`) when it has expired or is about to. Concurrent
/// callers that arrive while a refresh is already underway are coalesced onto that one
/// in-flight attempt rather than each triggering their own network round trip.
public actor TokenProvider {
    private let baseURL: URL
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
