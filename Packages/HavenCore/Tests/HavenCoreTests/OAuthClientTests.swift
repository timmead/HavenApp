import Testing
import Foundation
@testable import HavenCore

@Test func authorizeURLContainsClientAndRedirect() {
    let url = OAuthClient().authorizeURL(baseURL: URL(string: "http://ha.local:8123")!, state: "s1")
    let s = url.absoluteString
    #expect(s.hasPrefix("http://ha.local:8123/auth/authorize?"))
    #expect(s.contains("client_id=https%3A%2F%2Ftimmead.github.io%2FHavenApp%2Foauth%2F"))
    #expect(s.contains("redirect_uri=havenapp%3A%2F%2Foauth%2Fcallback"))
    #expect(s.contains("state=s1"))
}

@Test func loginExchangesCodeForTokens() async throws {
    let web = FakeWebAuth(returnURL: URL(string: "havenapp://oauth/callback?code=AUTHCODE&state=s1")!)
    let http = FakeHTTP(response: #"{"access_token":"AT","refresh_token":"RT","expires_in":1800}"#)
    let tokens = try await OAuthClient().login(baseURL: URL(string: "http://ha.local:8123")!,
                                               state: "s1", web: web, http: http)
    #expect(tokens.accessToken == "AT")
    #expect(tokens.refreshToken == "RT")
    #expect(http.lastForm?["code"] == "AUTHCODE")
    #expect(http.lastForm?["grant_type"] == "authorization_code")
}

@Test func mismatchedStateThrows() async throws {
    let web = FakeWebAuth(returnURL: URL(string: "havenapp://oauth/callback?code=X&state=WRONG")!)
    let http = FakeHTTP(response: "{}")
    await #expect(throws: (any Error).self) {
        _ = try await OAuthClient().login(baseURL: URL(string: "http://ha.local:8123")!,
                                          state: "s1", web: web, http: http)
    }
}
