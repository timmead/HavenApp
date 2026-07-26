import Testing
import Foundation
@testable import HavenCore

/// Mutable credentials double. Mutable on purpose: the failover case — the base URL changing
/// *between* two requests through the same loader — is the one this whole design exists for, and
/// it can only be exercised if the source can change under the loader.
private final class FakeImageCredentials: HAImageCredentialsProviding, @unchecked Sendable {
    var baseURL: URL
    var accessToken: String
    var error: Error?
    private(set) var callCount = 0

    init(baseURL: URL, accessToken: String = "tok-123") {
        self.baseURL = baseURL
        self.accessToken = accessToken
    }

    func imageCredentials() async throws -> HAImageCredentials {
        callCount += 1
        if let error { throw error }
        return HAImageCredentials(baseURL: baseURL, accessToken: accessToken)
    }
}

private final class FakeImageFetcher: HAImageFetching, @unchecked Sendable {
    struct Call: Equatable {
        let url: URL
        let bearerToken: String?
    }

    var body = Data("png-bytes".utf8)
    var status = 200
    var error: Error?
    private(set) var calls: [Call] = []

    func fetch(_ url: URL, bearerToken: String?) async throws -> (Data, Int) {
        calls.append(Call(url: url, bearerToken: bearerToken))
        if let error { throw error }
        return (body, status)
    }
}

/// Records the `Authorization` header seen at each hop of a request. Lock-protected because
/// `URLProtocol` hands its callbacks to us on URLSession's own queue.
private final class HopRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var hops: [(url: URL, authorization: String?)] = []

    func record(_ url: URL, _ authorization: String?) {
        lock.lock(); defer { lock.unlock() }
        hops.append((url, authorization))
    }

    func reset() { lock.lock(); hops.removeAll(); lock.unlock() }

    var seen: [(url: URL, authorization: String?)] {
        lock.lock(); defer { lock.unlock() }
        return hops
    }
}

/// Answers the first request with a 302 to another host, and that host with an image. Entirely
/// in-process — nothing here touches a network, let alone a live Home Assistant.
private final class RedirectingStubProtocol: URLProtocol {
    static let recorder = HopRecorder()
    static let origin = URL(string: "http://192.168.1.10:8123")!
    static let elsewhere = URL(string: "https://cdn.example.com/img")!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.recorder.record(url, request.value(forHTTPHeaderField: "Authorization"))
        if url.host == Self.origin.host {
            let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": Self.elsewhere.absoluteString])!
            // Carrying the original request's headers over is what makes this test bite: it is
            // what URLSession itself does for a redirect, and a freshly-built `URLRequest(url:)`
            // here would arrive header-less no matter whether the guard existed.
            var followOn = request
            followOn.url = Self.elsewhere
            client?.urlProtocol(self, wasRedirectedTo: followOn, redirectResponse: redirect)
            return
        }
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: ok, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("redirected-bytes".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite struct URLSessionImageFetcherTests {
    /// The gap a first-hop-only same-origin check leaves open: `URLSession` follows redirects on
    /// its own and re-sends the headers it was given, so without the guard this test's second hop
    /// would arrive at a third-party host carrying the user's Home Assistant token.
    @Test func authorizationHeaderIsStrippedWhenARedirectLeavesTheOrigin() async throws {
        RedirectingStubProtocol.recorder.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RedirectingStubProtocol.self]
        let fetcher = URLSessionImageFetcher(session: URLSession(configuration: config))

        let (data, status) = try await fetcher.fetch(
            RedirectingStubProtocol.origin.appending(path: "api/camera_proxy/camera.porch"),
            bearerToken: "tok-123")

        #expect(status == 200)
        #expect(data == Data("redirected-bytes".utf8))
        let hops = RedirectingStubProtocol.recorder.seen
        #expect(hops.count == 2)
        #expect(hops.first?.authorization == "Bearer tok-123")
        #expect(hops.last?.url.host == "cdn.example.com")
        #expect(hops.last?.authorization == nil)
    }
}

@Suite struct AuthenticatedImageLoaderTests {
    private let local = URL(string: "http://192.168.1.10:8123")!
    private let remote = URL(string: "https://abc123.ui.nabu.casa")!
    private let snapshotPath = "/api/camera_proxy/camera.porch"

    // MARK: - The token: attached to Home Assistant, and nowhere else

    @Test func attachesTheBearerTokenForARelativeHomeAssistantPath() async {
        let credentials = FakeImageCredentials(baseURL: local, accessToken: "tok-123")
        let fetcher = FakeImageFetcher()
        let loader = AuthenticatedImageLoader(credentials: credentials, fetcher: fetcher)

        let outcome = await loader.image(at: snapshotPath)

        #expect(outcome == .loaded(Data("png-bytes".utf8)))
        #expect(fetcher.calls == [.init(url: URL(string: "http://192.168.1.10:8123\(snapshotPath)")!,
                                        bearerToken: "tok-123")])
    }

    @Test func sendsNoTokenToAThirdPartyArtworkHost() async {
        let credentials = FakeImageCredentials(baseURL: local, accessToken: "tok-123")
        let fetcher = FakeImageFetcher()
        let loader = AuthenticatedImageLoader(credentials: credentials, fetcher: fetcher)

        _ = await loader.image(at: "https://i.scdn.co/image/ab67616d0000b273")

        #expect(fetcher.calls.count == 1)
        #expect(fetcher.calls[0].bearerToken == nil)
    }

    @Test func readsCredentialsFreshOnEveryRequest() async {
        // Nothing is captured: the loader asks again each time, so a token refreshed (or a host
        // failed over) between two requests is picked up without the loader being rebuilt.
        let credentials = FakeImageCredentials(baseURL: local, accessToken: "first")
        let fetcher = FakeImageFetcher()
        let loader = AuthenticatedImageLoader(credentials: credentials, fetcher: fetcher)

        _ = await loader.image(at: snapshotPath)
        credentials.accessToken = "second"
        _ = await loader.image(at: snapshotPath, policy: .reload)

        #expect(credentials.callCount == 2)
        #expect(fetcher.calls.map(\.bearerToken) == ["first", "second"])
    }

    // MARK: - The five outcomes stay five outcomes

    @Test func absentPathIsNoImageAndNeverReachesTheNetwork() async {
        let fetcher = FakeImageFetcher()
        let loader = AuthenticatedImageLoader(credentials: FakeImageCredentials(baseURL: local), fetcher: fetcher)

        #expect(await loader.image(at: nil) == .noImage)
        #expect(await loader.image(at: "") == .noImage)
        #expect(await loader.image(at: "   ") == .noImage)
        #expect(fetcher.calls.isEmpty)
    }

    @Test func missingTokenIsDistinctFromAFailedLoad() async {
        // The requirement in one test: "there is no session" and "the fetch failed" are different
        // answers, because they call for different UI — sign in, versus retry/show an error.
        let credentials = FakeImageCredentials(baseURL: local)
        credentials.error = TokenProviderError.reauthenticationRequired
        let fetcher = FakeImageFetcher()
        let loader = AuthenticatedImageLoader(credentials: credentials, fetcher: fetcher)

        let outcome = await loader.image(at: snapshotPath)

        #expect(outcome == .noCredentials(.reauthenticationRequired))
        if case .failed = outcome { Issue.record("a missing token must not be reported as a load failure") }
        // And nothing was requested — an unauthenticated GET would just 401.
        #expect(fetcher.calls.isEmpty)
    }

    @Test func blockedTransportReasonSurvivesToTheCaller() async {
        // `insecureTransportBlocked` is terminal, configuration-caused, and carries user-facing
        // copy. Collapsing it into a generic "no credentials" would discard the only thing that
        // tells the user what to change.
        let credentials = FakeImageCredentials(baseURL: local)
        credentials.error = TokenProviderError.insecureTransportBlocked(host: "ha.example.com")
        let loader = AuthenticatedImageLoader(credentials: credentials, fetcher: FakeImageFetcher())

        let outcome = await loader.image(at: snapshotPath)

        #expect(outcome == .noCredentials(.insecureTransportBlocked(host: "ha.example.com")))
        if case .noCredentials(let reason) = outcome {
            #expect(reason.message?.contains("ha.example.com") == true)
        }
    }

    @Test func rejectedTokenIsReportedAsUnauthorizedRatherThanABlankImage() async {
        // The bug this feature exists to prevent: `AsyncImage` renders its placeholder on a 401,
        // so a camera the token can't read looks identical to a camera with nothing in front of it.
        let fetcher = FakeImageFetcher()
        fetcher.status = 401
        fetcher.body = Data()
        let loader = AuthenticatedImageLoader(credentials: FakeImageCredentials(baseURL: local), fetcher: fetcher)

        #expect(await loader.image(at: snapshotPath) == .failed(.unauthorized))
    }

    @Test func otherHTTPStatusesKeepTheirCode() async {
        let fetcher = FakeImageFetcher()
        fetcher.status = 500
        let loader = AuthenticatedImageLoader(credentials: FakeImageCredentials(baseURL: local), fetcher: fetcher)

        #expect(await loader.image(at: snapshotPath) == .failed(.httpStatus(500)))
    }

    @Test func successfulResponseWithNoBytesIsAFailure() async {
        let fetcher = FakeImageFetcher()
        fetcher.body = Data()
        let loader = AuthenticatedImageLoader(credentials: FakeImageCredentials(baseURL: local), fetcher: fetcher)

        #expect(await loader.image(at: snapshotPath) == .failed(.emptyResponse))
    }

    @Test func transportFailureCarriesNoURLAndSoNoSignedToken() async {
        // The resolved URL is credential-bearing (`?token=…`), and `NSError`'s user info embeds the
        // failing URL — so the identifier here is deliberately coarse.
        let fetcher = FakeImageFetcher()
        fetcher.error = URLError(.timedOut)
        let loader = AuthenticatedImageLoader(credentials: FakeImageCredentials(baseURL: local), fetcher: fetcher)

        let outcome = await loader.image(at: "/api/media_player_proxy/media_player.kitchen?token=secret-sig")

        #expect(outcome == .failed(.transport("URLError \(URLError.Code.timedOut.rawValue)")))
        if case .failed(.transport(let identifier)) = outcome {
            #expect(!identifier.contains("secret-sig"))
        }
    }

    @Test func cancellationIsNotAnError() async {
        // A tile scrolling away cancels its own load. Reporting that as a failure makes a scrolling
        // dashboard flash error states for work it deliberately abandoned.
        for error in [CancellationError() as Error, URLError(.cancelled) as Error] {
            let fetcher = FakeImageFetcher()
            fetcher.error = error
            let loader = AuthenticatedImageLoader(credentials: FakeImageCredentials(baseURL: local), fetcher: fetcher)
            #expect(await loader.image(at: snapshotPath) == .cancelled)
        }
    }

    @Test func malformedPathFailsWithoutReachingTheNetwork() async {
        let fetcher = FakeImageFetcher()
        let loader = AuthenticatedImageLoader(credentials: FakeImageCredentials(baseURL: local), fetcher: fetcher)

        let outcome = await loader.image(at: "data:image/png;base64,iVBORw0KGgo=")

        #expect(outcome == .failed(.unresolvable(.unsupportedScheme("data"))))
        #expect(fetcher.calls.isEmpty)
    }

    // MARK: - Cache

    @Test func secondRequestForTheSameImageIsServedFromMemory() async {
        let fetcher = FakeImageFetcher()
        let loader = AuthenticatedImageLoader(credentials: FakeImageCredentials(baseURL: local), fetcher: fetcher)

        _ = await loader.image(at: snapshotPath)
        let second = await loader.image(at: snapshotPath)

        #expect(second == .loaded(Data("png-bytes".utf8)))
        #expect(fetcher.calls.count == 1)
    }

    @Test func aBaseURLChangeDoesNotServeTheStaleHostsImage() async {
        // Failover: the same path now means a different host, so the cached bytes must not be
        // reused — the cache is keyed on the resolved URL, which carries the origin.
        let credentials = FakeImageCredentials(baseURL: local)
        let fetcher = FakeImageFetcher()
        let loader = AuthenticatedImageLoader(credentials: credentials, fetcher: fetcher)

        _ = await loader.image(at: snapshotPath)
        credentials.baseURL = remote
        _ = await loader.image(at: snapshotPath)

        #expect(fetcher.calls.count == 2)
        #expect(fetcher.calls.map { $0.url.host() } == ["192.168.1.10", "abc123.ui.nabu.casa"])
        // Back to the local address: that one *is* still cached, so failing back doesn't re-fetch.
        credentials.baseURL = local
        _ = await loader.image(at: snapshotPath)
        #expect(fetcher.calls.count == 2)
    }

    @Test func reloadPolicyBypassesAndReplacesTheCachedCopy() async {
        // What the camera tiles' periodic refresh needs: the snapshot URL is stable and its
        // contents are the thing that changes.
        let fetcher = FakeImageFetcher()
        let loader = AuthenticatedImageLoader(credentials: FakeImageCredentials(baseURL: local), fetcher: fetcher)

        _ = await loader.image(at: snapshotPath)
        fetcher.body = Data("newer-frame".utf8)
        #expect(await loader.image(at: snapshotPath, policy: .reload) == .loaded(Data("newer-frame".utf8)))
        // The refreshed frame replaced the old one rather than sitting beside it.
        #expect(await loader.image(at: snapshotPath) == .loaded(Data("newer-frame".utf8)))
        #expect(fetcher.calls.count == 2)
    }

    @Test func failuresAreNeverCached() async {
        // A transient failure must not permanently block a later retry — the rule `HomeStore`
        // already follows for history series.
        let fetcher = FakeImageFetcher()
        fetcher.error = URLError(.timedOut)
        let loader = AuthenticatedImageLoader(credentials: FakeImageCredentials(baseURL: local), fetcher: fetcher)

        _ = await loader.image(at: snapshotPath)
        fetcher.error = nil
        #expect(await loader.image(at: snapshotPath) == .loaded(Data("png-bytes".utf8)))
    }

    @Test func cacheIsBoundedAndEvictsOldestFirst() async {
        let fetcher = FakeImageFetcher()
        let loader = AuthenticatedImageLoader(credentials: FakeImageCredentials(baseURL: local),
                                              fetcher: fetcher, cacheLimit: 2)

        _ = await loader.image(at: "/api/camera_proxy/camera.one")
        _ = await loader.image(at: "/api/camera_proxy/camera.two")
        _ = await loader.image(at: "/api/camera_proxy/camera.three")
        // `two` and `three` are still resident; `one` was evicted and costs one more request.
        _ = await loader.image(at: "/api/camera_proxy/camera.two")
        #expect(fetcher.calls.count == 3)
        _ = await loader.image(at: "/api/camera_proxy/camera.one")
        #expect(fetcher.calls.count == 4)
    }

    // MARK: - What a renderer does with an outcome

    @Test func failureNeverRendersAsAnInnocentBlank() {
        // The whole feature in one assertion: only "this entity has no picture" is allowed to
        // render as empty. Every way of *failing* renders as a failure.
        #expect(ImageLoadOutcome.noImage.displayState == .empty)
        #expect(ImageLoadOutcome.failed(.unauthorized).displayState == .failure)
        #expect(ImageLoadOutcome.failed(.emptyResponse).displayState == .failure)
        #expect(ImageLoadOutcome.failed(.httpStatus(404)).displayState == .failure)
        #expect(ImageLoadOutcome.failed(.transport("URLError -1001")).displayState == .failure)
        #expect(ImageLoadOutcome.failed(.unresolvable(.unsupportedScheme("data"))).displayState == .failure)
        #expect(ImageLoadOutcome.noCredentials(.reauthenticationRequired).displayState == .failure)
        #expect(ImageLoadOutcome.loaded(Data("x".utf8)).displayState == .image(Data("x".utf8)))
    }

    @Test func cancellationLeavesWhateverIsOnScreenAlone() {
        #expect(ImageLoadOutcome.cancelled.displayState == nil)
    }

    @Test func clearCacheDropsEverything() async {
        let fetcher = FakeImageFetcher()
        let loader = AuthenticatedImageLoader(credentials: FakeImageCredentials(baseURL: local), fetcher: fetcher)

        _ = await loader.image(at: snapshotPath)
        await loader.clearCache()
        _ = await loader.image(at: snapshotPath)

        #expect(fetcher.calls.count == 2)
    }
}
