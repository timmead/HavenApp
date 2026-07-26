import Testing
import Foundation
@testable import HavenCore

private let baseURL = URL(string: "http://ha.local:8123")!

@Test func stillValidTokenReturnedWithoutHTTPCall() async throws {
    let now = Date()
    let store = InMemoryTokenStore(HATokens(accessToken: "AT1", refreshToken: "RT1",
                                             expiresAt: now.addingTimeInterval(3600)))
    let http = FakeHTTP(response: "should not be used")
    let provider = TokenProvider(baseURL: baseURL, store: store, oauth: OAuthClient(), http: http)

    let token = try await provider.validAccessToken(now: now)

    #expect(token == "AT1")
    #expect(http.callCount == 0)
}

@Test func expiredTokenTriggersExactlyOneRefreshAndPersists() async throws {
    let now = Date()
    let store = InMemoryTokenStore(HATokens(accessToken: "AT1", refreshToken: "RT1",
                                             expiresAt: now.addingTimeInterval(-10)))
    let http = FakeHTTP(response: #"{"access_token":"AT2","refresh_token":"RT2","expires_in":1800}"#)
    let provider = TokenProvider(baseURL: baseURL, store: store, oauth: OAuthClient(), http: http)

    let token = try await provider.validAccessToken(now: now)

    #expect(token == "AT2")
    #expect(http.callCount == 1)
    #expect(http.lastForm?["grant_type"] == "refresh_token")
    #expect(http.lastForm?["refresh_token"] == "RT1")
    #expect(store.saveCount == 1)
    #expect(store.current?.accessToken == "AT2")
    #expect(store.current?.refreshToken == "RT2")
}

@Test func tokenInsideSkewWindowRefreshes() async throws {
    let now = Date()
    // 30s to live is inside the default 60s skew — must be treated as needing refresh.
    let store = InMemoryTokenStore(HATokens(accessToken: "AT1", refreshToken: "RT1",
                                             expiresAt: now.addingTimeInterval(30)))
    let http = FakeHTTP(response: #"{"access_token":"AT2","refresh_token":"RT2","expires_in":1800}"#)
    let provider = TokenProvider(baseURL: baseURL, store: store, oauth: OAuthClient(), http: http)

    let token = try await provider.validAccessToken(now: now)

    #expect(token == "AT2")
    #expect(http.callCount == 1)
}

@Test func tokenWellOutsideSkewWindowIsNotRefreshed() async throws {
    let now = Date()
    // 600s to live is well outside the 60s skew — should be returned as-is.
    let store = InMemoryTokenStore(HATokens(accessToken: "AT1", refreshToken: "RT1",
                                             expiresAt: now.addingTimeInterval(600)))
    let http = FakeHTTP(response: "should not be used")
    let provider = TokenProvider(baseURL: baseURL, store: store, oauth: OAuthClient(), http: http)

    let token = try await provider.validAccessToken(now: now)

    #expect(token == "AT1")
    #expect(http.callCount == 0)
}

@Test func concurrentCallersCoalesceIntoOneRefresh() async throws {
    let now = Date()
    let store = InMemoryTokenStore(HATokens(accessToken: "AT1", refreshToken: "RT1",
                                             expiresAt: now.addingTimeInterval(-10)))
    let http = FakeHTTP(response: #"{"access_token":"AT2","refresh_token":"RT2","expires_in":1800}"#)
    // Hold the "network" call open so all three callers are guaranteed to arrive at the actor
    // while the first refresh is still in flight — otherwise callCount == 1 could also happen
    // by accident (e.g. callers #2/#3 racing in after the first refresh already completed and
    // persisted a non-expired token). `async let` starts eagerly, so all three reach the actor
    // before this delay elapses.
    http.delay = .milliseconds(100)
    let provider = TokenProvider(baseURL: baseURL, store: store, oauth: OAuthClient(), http: http)

    async let first = provider.validAccessToken(now: now)
    async let second = provider.validAccessToken(now: now)
    async let third = provider.validAccessToken(now: now)
    let (a, b, c) = try await (first, second, third)

    #expect(a == "AT2")
    #expect(b == "AT2")
    #expect(c == "AT2")
    #expect(http.callCount == 1)
    #expect(store.saveCount == 1)
}

@Test func missingRefreshTokenThrowsReauthenticationRequired() async throws {
    let now = Date()
    let store = InMemoryTokenStore(HATokens(accessToken: "AT1", refreshToken: nil,
                                             expiresAt: now.addingTimeInterval(-10)))
    let http = FakeHTTP(response: "unused")
    let provider = TokenProvider(baseURL: baseURL, store: store, oauth: OAuthClient(), http: http)

    await #expect(throws: TokenProviderError.reauthenticationRequired) {
        _ = try await provider.validAccessToken(now: now)
    }
    #expect(http.callCount == 0)
}

@Test func noStoredSessionThrowsReauthenticationRequired() async throws {
    let store = InMemoryTokenStore(nil)
    let http = FakeHTTP(response: "unused")
    let provider = TokenProvider(baseURL: baseURL, store: store, oauth: OAuthClient(), http: http)

    await #expect(throws: TokenProviderError.reauthenticationRequired) {
        _ = try await provider.validAccessToken(now: Date())
    }
    #expect(http.callCount == 0)
}

@Test func invalidGrantOnRefreshThrowsReauthenticationRequiredAndClearsStore() async throws {
    let now = Date()
    let store = InMemoryTokenStore(HATokens(accessToken: "AT1", refreshToken: "RT1",
                                             expiresAt: now.addingTimeInterval(-10)))
    let http = FakeHTTP(response: "unused")
    http.error = WSError(code: WSError.invalidGrantCode, message: "token endpoint rejected the request (400)")
    let provider = TokenProvider(baseURL: baseURL, store: store, oauth: OAuthClient(), http: http)

    await #expect(throws: TokenProviderError.reauthenticationRequired) {
        _ = try await provider.validAccessToken(now: now)
    }
    #expect(store.current == nil)
}

@Test func forceRefreshRefreshesEvenWhenTokenNotExpired() async throws {
    let now = Date()
    // Well outside the skew window — validAccessToken would return this as-is.
    let store = InMemoryTokenStore(HATokens(accessToken: "AT1", refreshToken: "RT1",
                                             expiresAt: now.addingTimeInterval(3600)))
    let http = FakeHTTP(response: #"{"access_token":"AT2","refresh_token":"RT2","expires_in":1800}"#)
    let provider = TokenProvider(baseURL: baseURL, store: store, oauth: OAuthClient(), http: http)

    let token = try await provider.forceRefresh()

    #expect(token == "AT2")
    #expect(http.callCount == 1)
    #expect(store.current?.accessToken == "AT2")
}

@Test func forceRefreshWithNoRefreshTokenThrowsReauthenticationRequired() async throws {
    let now = Date()
    let store = InMemoryTokenStore(HATokens(accessToken: "AT1", refreshToken: nil,
                                             expiresAt: now.addingTimeInterval(3600)))
    let http = FakeHTTP(response: "unused")
    let provider = TokenProvider(baseURL: baseURL, store: store, oauth: OAuthClient(), http: http)

    await #expect(throws: TokenProviderError.reauthenticationRequired) {
        _ = try await provider.forceRefresh()
    }
    #expect(http.callCount == 0)
}

@Test func transientRefreshFailurePropagatesUnderlyingError() async throws {
    let now = Date()
    let store = InMemoryTokenStore(HATokens(accessToken: "AT1", refreshToken: "RT1",
                                             expiresAt: now.addingTimeInterval(-10)))
    let http = FakeHTTP(response: "unused")
    http.error = WSError(code: "http", message: "token endpoint failed (500)")
    let provider = TokenProvider(baseURL: baseURL, store: store, oauth: OAuthClient(), http: http)

    await #expect(throws: WSError.self) {
        _ = try await provider.validAccessToken(now: now)
    }
    // Not a reauth signal — session must remain intact so the caller can retry.
    #expect(store.current?.accessToken == "AT1")
}

// MARK: - Fix-round regression tests

@Test func secondRefreshAfterFirstCompletesStillPerformsANetworkCall() async throws {
    // Guards against the in-flight `Task` being left cached forever, which would make every
    // refresh after the very first one a silent no-op returning a stale token.
    let now = Date()
    let store = InMemoryTokenStore(HATokens(accessToken: "AT1", refreshToken: "RT1",
                                             expiresAt: now.addingTimeInterval(-10)))
    let http = FakeHTTP(response: #"{"access_token":"AT2","refresh_token":"RT2","expires_in":30}"#)
    let provider = TokenProvider(baseURL: baseURL, store: store, oauth: OAuthClient(), http: http)

    let first = try await provider.validAccessToken(now: now)
    #expect(first == "AT2")
    #expect(http.callCount == 1)

    http.response = #"{"access_token":"AT3","refresh_token":"RT3","expires_in":1800}"#
    // Well past AT2's real (wall-clock-based) expiry of `now + 30s`.
    let muchLater = now.addingTimeInterval(3600)
    let second = try await provider.validAccessToken(now: muchLater)

    #expect(second == "AT3")
    #expect(http.callCount == 2)
    #expect(store.current?.accessToken == "AT3")
}

@Test func refreshWorksAgainAfterATransientFailure() async throws {
    // Guards against a failed refresh leaving `refreshTask` in a state that blocks (or silently
    // no-ops) the next legitimate attempt.
    let now = Date()
    let store = InMemoryTokenStore(HATokens(accessToken: "AT1", refreshToken: "RT1",
                                             expiresAt: now.addingTimeInterval(-10)))
    let http = FakeHTTP(response: "unused")
    http.error = WSError(code: "http", message: "token endpoint failed (500)")
    let provider = TokenProvider(baseURL: baseURL, store: store, oauth: OAuthClient(), http: http)

    await #expect(throws: WSError.self) {
        _ = try await provider.validAccessToken(now: now)
    }
    #expect(http.callCount == 1)

    http.error = nil
    http.response = #"{"access_token":"AT2","refresh_token":"RT2","expires_in":1800}"#
    let token = try await provider.validAccessToken(now: now)

    #expect(token == "AT2")
    #expect(http.callCount == 2)
}

@Test func refreshResponseWithoutRefreshTokenPreservesExistingGrant() async throws {
    // This is what Home Assistant actually returns on a refresh — no `refresh_token` field — and
    // it's what makes a *second* refresh possible at all (OAuthClient.parseTokens falls back to
    // the refresh token that was used for the request when the response omits one).
    let now = Date()
    let store = InMemoryTokenStore(HATokens(accessToken: "AT1", refreshToken: "RT1",
                                             expiresAt: now.addingTimeInterval(-10)))
    let http = FakeHTTP(response: #"{"access_token":"AT2","expires_in":30}"#)
    let provider = TokenProvider(baseURL: baseURL, store: store, oauth: OAuthClient(), http: http)

    let token = try await provider.validAccessToken(now: now)
    #expect(token == "AT2")
    #expect(store.current?.refreshToken == "RT1")

    // And a later refresh still works, because the refresh token survived.
    http.response = #"{"access_token":"AT3","expires_in":1800}"#
    let muchLater = now.addingTimeInterval(3600)
    let second = try await provider.validAccessToken(now: muchLater)

    #expect(second == "AT3")
    #expect(store.current?.refreshToken == "RT1")
    #expect(http.callCount == 2)
}

@Test func setBaseURLRedirectsWhereAFutureRefreshPosts() async throws {
    // Guards the candidate-failover fix: AppModel.connect() calls setBaseURL(candidate.url)
    // before every attempt, so a refresh triggered while trying the *remote* candidate must POST
    // there, not to whatever host this TokenProvider was originally constructed with (or last
    // left pointed at by a previous, failed local candidate).
    let now = Date()
    let store = InMemoryTokenStore(HATokens(accessToken: "AT1", refreshToken: "RT1",
                                             expiresAt: now.addingTimeInterval(-10)))
    let http = FakeHTTP(response: #"{"access_token":"AT2","refresh_token":"RT2","expires_in":1800}"#)
    let provider = TokenProvider(baseURL: baseURL, store: store, oauth: OAuthClient(), http: http)

    let remote = URL(string: "https://abc123.ui.nabu.casa")!
    await provider.setBaseURL(remote)
    _ = try await provider.validAccessToken(now: now)

    #expect(http.lastURL == remote.appendingPathComponent("auth/token"))
}

@Test func setBaseURLAlsoRedirectsForceRefresh() async throws {
    let now = Date()
    let store = InMemoryTokenStore(HATokens(accessToken: "AT1", refreshToken: "RT1",
                                             expiresAt: now.addingTimeInterval(3600)))
    let http = FakeHTTP(response: #"{"access_token":"AT2","refresh_token":"RT2","expires_in":1800}"#)
    let provider = TokenProvider(baseURL: baseURL, store: store, oauth: OAuthClient(), http: http)

    let remote = URL(string: "https://abc123.ui.nabu.casa")!
    await provider.setBaseURL(remote)
    _ = try await provider.forceRefresh()

    #expect(http.lastURL == remote.appendingPathComponent("auth/token"))
}

@Test func invalidatePreventsAPendingRefreshFromWritingToTheStore() async throws {
    let now = Date()
    let store = InMemoryTokenStore(HATokens(accessToken: "AT1", refreshToken: "RT1",
                                             expiresAt: now.addingTimeInterval(-10)))
    let http = FakeHTTP(response: #"{"access_token":"AT2","refresh_token":"RT2","expires_in":1800}"#)
    http.delay = .milliseconds(150)
    let provider = TokenProvider(baseURL: baseURL, store: store, oauth: OAuthClient(), http: http)

    async let pending: String? = try? await provider.validAccessToken(now: now)
    // Give the refresh a moment to actually enter FakeHTTP.post (and thus be "in flight") before
    // invalidating — mirrors sign-out racing with an in-progress refresh.
    try await Task.sleep(for: .milliseconds(30))
    await provider.invalidate()
    // Simulate the store having moved on to a brand-new session in the meantime (e.g. the user
    // signed out and completed OAuth against a different host while the old refresh was still
    // awaiting the network). This is exactly what must survive.
    store.current = HATokens(accessToken: "NEWSESSION", refreshToken: "NEWRT",
                              expiresAt: now.addingTimeInterval(3600))

    _ = await pending // may resolve to nil (thrown/swallowed) — only the store matters here
    #expect(store.current?.accessToken == "NEWSESSION")
    #expect(store.current?.refreshToken == "NEWRT")
}

// MARK: - App Transport Security (-1022): terminal and named, never transient
//
// The failure this classification exists to remove is a *silent hang*, and it is the shape this
// project has shipped three times: a wrong assumption producing a confident wrong state rather than
// an error. A user signed in against a cleartext `http://` FQDN that resolves to a LAN address keeps
// working — right up until the access token expires hours later and the refresh POST is refused by
// ATS. Unclassified, that arrives at `AppModel` as an opaque `URLError`, is handled by the same
// generic `catch` as "Wi-Fi dropped", and feeds the unbounded retry loop: "connecting…" forever,
// with nothing anywhere naming ATS. It also cannot show up in testing that immediately follows the
// plist change, because the trigger is the token expiry, not the change.

@Test func atsBlockedRefreshIsClassifiedTerminalNotTransient() async throws {
    let now = Date()
    let store = InMemoryTokenStore(HATokens(accessToken: "AT1", refreshToken: "RT1",
                                             expiresAt: now.addingTimeInterval(-10)))
    let http = FakeHTTP(response: "unused")
    // Exactly what URLSession throws when ATS refuses the request: -1022.
    http.error = URLError(.appTransportSecurityRequiresSecureConnection)
    let provider = TokenProvider(baseURL: URL(string: "http://hass.example.com")!,
                                 store: store, oauth: OAuthClient(), http: http)

    // Named — not the raw URLError that `transientRefreshFailurePropagatesUnderlyingError` shows
    // every other network failure surfacing as, and which the caller retries.
    await #expect(throws: TokenProviderError.insecureTransportBlocked(host: "hass.example.com")) {
        _ = try await provider.validAccessToken(now: now)
    }
    #expect(TokenProviderError.insecureTransportBlocked(host: "hass.example.com").isTerminal)
    // The distinction that stops the retry loop: every other refresh failure is non-terminal.
    #expect(!TokenProviderError.invalidated.isTerminal)
}

@Test func anATSBlockedRefreshLeavesTheSessionIntact() async throws {
    // Unlike `invalid_grant`, the grant is untouched — the *address* is wrong. Clearing the store
    // here would sign a user out of a perfectly good session over a URL they can simply edit, and
    // would also lose the refresh token they need for the address they change it to.
    let now = Date()
    let store = InMemoryTokenStore(HATokens(accessToken: "AT1", refreshToken: "RT1",
                                             expiresAt: now.addingTimeInterval(-10)))
    let http = FakeHTTP(response: "unused")
    http.error = URLError(.appTransportSecurityRequiresSecureConnection)
    let provider = TokenProvider(baseURL: URL(string: "http://hass.example.com")!,
                                 store: store, oauth: OAuthClient(), http: http)

    _ = try? await provider.validAccessToken(now: now)

    #expect(store.current?.accessToken == "AT1")
    #expect(store.current?.refreshToken == "RT1")
}

@Test func aForcedRefreshIsBlockedTheSameWay() async throws {
    // `forceRefresh` is the path taken after Home Assistant answers `auth_invalid`, and it goes
    // through the same `refresh` — so it must classify identically rather than leaking a URLError
    // out of a second route.
    let now = Date()
    let store = InMemoryTokenStore(HATokens(accessToken: "AT1", refreshToken: "RT1",
                                             expiresAt: now.addingTimeInterval(3600)))
    let http = FakeHTTP(response: "unused")
    http.error = URLError(.appTransportSecurityRequiresSecureConnection)
    let provider = TokenProvider(baseURL: URL(string: "http://hass.example.com")!,
                                 store: store, oauth: OAuthClient(), http: http)

    await #expect(throws: TokenProviderError.insecureTransportBlocked(host: "hass.example.com")) {
        _ = try await provider.forceRefresh()
    }
}

@Test func theBlockedHostFollowsSetBaseURLRatherThanTheOriginalOne() async throws {
    // `AppModel` repoints the provider at each candidate before trying it, so the host named in the
    // message must be the candidate that was actually refused — otherwise the remedy would point at
    // an address that is working fine.
    let now = Date()
    let store = InMemoryTokenStore(HATokens(accessToken: "AT1", refreshToken: "RT1",
                                             expiresAt: now.addingTimeInterval(-10)))
    let http = FakeHTTP(response: "unused")
    http.error = URLError(.appTransportSecurityRequiresSecureConnection)
    let provider = TokenProvider(baseURL: URL(string: "http://192.168.1.10:8123")!,
                                 store: store, oauth: OAuthClient(), http: http)

    await provider.setBaseURL(URL(string: "http://hass.example.com")!)

    await #expect(throws: TokenProviderError.insecureTransportBlocked(host: "hass.example.com")) {
        _ = try await provider.validAccessToken(now: now)
    }
}

@Test func theBlockedMessageNamesTheAddressAndBothWaysOut() async throws {
    // The message is the fix — a silent hang made into a named failure — so it lives in HavenCore
    // and is asserted rather than trusted. `App/` has no test target.
    let message = TokenProviderError.insecureTransportBlocked(host: "hass.example.com").message
    #expect(message?.contains("hass.example.com") == true)
    #expect(message?.contains("http://") == true)
    #expect(message?.contains("https://hass.example.com") == true)
    #expect(message?.contains("local network address") == true)
    // Nothing to say where there is nothing the user can do about it.
    #expect(TokenProviderError.reauthenticationRequired.message == nil)
    #expect(TokenProviderError.invalidated.message == nil)
}
