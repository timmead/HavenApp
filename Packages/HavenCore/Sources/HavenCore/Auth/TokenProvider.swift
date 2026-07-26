import Foundation

/// Thrown by `TokenProvider` when the stored session can no longer produce a usable access
/// token and the only remaining option is to send the user back through sign-in.
public enum TokenProviderError: Error, Sendable, Equatable {
    case reauthenticationRequired
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

    private func refresh(refreshToken: String) async throws -> String {
        let task = Task<String, Error> {
            do {
                let refreshed = try await self.oauth.refresh(baseURL: self.baseURL, refreshToken: refreshToken, http: self.http)
                try self.store.save(refreshed)
                return refreshed.accessToken
            } catch let wsError as WSError where wsError.isInvalidGrant {
                // The refresh token itself was rejected — no amount of retrying will help;
                // the user must sign in again.
                self.store.clear()
                throw TokenProviderError.reauthenticationRequired
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }
}
