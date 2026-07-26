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
