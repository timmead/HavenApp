import Testing
import Foundation
@testable import HavenCore

/// Stubs an HTTP response entirely from the request URL's query items, so tests don't need any
/// shared mutable state (and are therefore safe under Swift Testing's parallel execution).
private final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let statusCode = items.first(where: { $0.name == "status" })?.value.flatMap(Int.init) ?? 200
        let bodyText = items.first(where: { $0.name == "body" })?.value ?? ""
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(bodyText.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubbedHTTP() -> URLSessionHTTP {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSessionHTTP(session: URLSession(configuration: config))
}

private func stubURL(status: Int, body: String? = nil) -> URL {
    var comps = URLComponents(string: "http://ha.local/auth/token")!
    var items = [URLQueryItem(name: "status", value: String(status))]
    if let body { items.append(URLQueryItem(name: "body", value: body)) }
    comps.queryItems = items
    return comps.url!
}

@Test func rfc6749InvalidGrantBodyClassifiesAsInvalidGrant() async throws {
    let http = stubbedHTTP()
    let url = stubURL(status: 400, body: #"{"error":"invalid_grant"}"#)

    await #expect(throws: WSError(code: WSError.invalidGrantCode, message: "token endpoint rejected the request (400)")) {
        _ = try await http.post(url, form: [:])
    }
}

@Test func bodylessUnauthorizedFromAReverseProxyIsTransientNotInvalidGrant() async throws {
    // A reverse proxy (Authelia, Cloudflare Access, etc.) whose own session expired in front of
    // Home Assistant can also return a bare 401 — that must NOT be treated as proof the OAuth
    // grant itself is dead, since doing so would destroy the keychain on what may just be a
    // flaky/unrelated infra moment.
    let http = stubbedHTTP()
    let url = stubURL(status: 401)

    await #expect(throws: WSError(code: "http", message: "token endpoint failed (401)")) {
        _ = try await http.post(url, form: [:])
    }
}

@Test func differentlyShapedErrorBodyOn400IsTransientNotInvalidGrant() async throws {
    let http = stubbedHTTP()
    let url = stubURL(status: 400, body: #"{"error":"server_error"}"#)

    await #expect(throws: WSError(code: "http", message: "token endpoint failed (400)")) {
        _ = try await http.post(url, form: [:])
    }
}

@Test func defaultSessionFailsFastAgainstAnUnreachableHostRatherThanHangingOnSharedsDefaults() async throws {
    // Candidate failover's token refresh is often the very first network call made against a
    // candidate — it must not hang anywhere near URLSession.shared's default (~60s) timeout, or a
    // cold launch away from home stalls the whole connect attempt before a socket is ever opened.
    // 192.0.2.0/24 (IANA TEST-NET-1) is reserved and guaranteed to never have a live host.
    let http = URLSessionHTTP()
    let start = Date()
    await #expect(throws: Error.self) {
        _ = try await http.post(URL(string: "http://192.0.2.1:8123/auth/token")!, form: [:])
    }
    #expect(Date().timeIntervalSince(start) < 15)
}
