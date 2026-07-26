import Testing
import Foundation
@testable import HavenCore

@Suite struct HAImageURLTests {
    private func url(_ s: String) -> URL { URL(string: s)! }
    private let local = URL(string: "http://192.168.1.10:8123")!
    private let remote = URL(string: "https://abc123.ui.nabu.casa")!

    // MARK: - Resolution

    @Test func relativePathResolvesAgainstTheBaseURL() throws {
        let resolved = try HAImageURL.resolve(path: "/api/camera_proxy/camera.porch", baseURL: local)
        #expect(resolved.url == url("http://192.168.1.10:8123/api/camera_proxy/camera.porch"))
        #expect(resolved.authorize)
    }

    @Test func relativePathKeepsItsQuery() throws {
        // Home Assistant's `entity_picture` carries a signed token in the query. It is part of the
        // reference, not decoration — dropping it yields a URL that 401s.
        let resolved = try HAImageURL.resolve(
            path: "/api/media_player_proxy/media_player.kitchen?token=abc&cache=xyz", baseURL: local)
        #expect(resolved.url.query() == "token=abc&cache=xyz")
        #expect(resolved.authorize)
    }

    @Test func relativePathResolvesAgainstWhicheverBaseURLItIsGiven() throws {
        // The same path against the two addresses of one instance. This is the failover case: the
        // caller passes the base URL live *at request time*, and gets a URL for that host.
        let a = try HAImageURL.resolve(path: "/api/camera_proxy/camera.porch", baseURL: local)
        let b = try HAImageURL.resolve(path: "/api/camera_proxy/camera.porch", baseURL: remote)
        #expect(a.url.host() == "192.168.1.10")
        #expect(b.url.host() == "abc123.ui.nabu.casa")
        #expect(a.authorize && b.authorize)
    }

    @Test func basePathPrefixIsReplacedByAnAbsolutePath() throws {
        // A base URL behind a reverse-proxy subpath. An absolute-path reference is absolute
        // *against the origin*, exactly as a browser would resolve it.
        let resolved = try HAImageURL.resolve(path: "/api/camera_proxy/camera.porch",
                                              baseURL: url("https://ha.example.com/subpath"))
        #expect(resolved.url == url("https://ha.example.com/api/camera_proxy/camera.porch"))
    }

    @Test func absoluteURLIsPassedThroughUntouched() throws {
        // Sonos and Spotify both hand back absolute artwork URLs. Nothing is rewritten.
        let resolved = try HAImageURL.resolve(path: "https://i.scdn.co/image/ab67616d0000b273", baseURL: local)
        #expect(resolved.url == url("https://i.scdn.co/image/ab67616d0000b273"))
    }

    @Test func absoluteForeignURLIsNotAuthorized() throws {
        // The single most important assertion in this file: the bearer token is a credential for
        // the user's home, and a third-party artwork host must never receive it.
        let spotify = try HAImageURL.resolve(path: "https://i.scdn.co/image/ab67616d0000b273", baseURL: local)
        #expect(!spotify.authorize)
        // A Sonos speaker on the same LAN is still a different origin — same network is not same host.
        let sonos = try HAImageURL.resolve(path: "http://192.168.1.30:1400/getaa?psz=500", baseURL: local)
        #expect(!sonos.authorize)
        // And the *other* address of this same instance, after a failover, is cross-origin too:
        // the load fails visibly rather than sending the token somewhere we aren't talking to.
        let otherAddress = try HAImageURL.resolve(path: "http://192.168.1.10:8123/api/camera_proxy/camera.porch",
                                                  baseURL: remote)
        #expect(!otherAddress.authorize)
    }

    @Test func absoluteURLMatchingTheBaseOriginIsAuthorized() throws {
        let resolved = try HAImageURL.resolve(path: "http://192.168.1.10:8123/api/camera_proxy/camera.porch",
                                              baseURL: local)
        #expect(resolved.authorize)
    }

    @Test func originComparisonIgnoresCaseAndDefaultPorts() throws {
        // Same origin written three ways. Comparison is `ConnectionEndpoint.normalizedKey`, so an
        // implicit :443 and an upper-case host don't cost a same-origin request its header.
        let resolved = try HAImageURL.resolve(path: "https://HA.example.com:443/api/camera_proxy/camera.porch",
                                              baseURL: url("https://ha.example.com"))
        #expect(resolved.authorize)
    }

    @Test func protocolRelativeReferenceToAnotherHostIsNotAuthorized() throws {
        // `//host/path` inherits only the scheme from the base — the host is the attacker's. It
        // looks relative, so it is exactly the shape that could slip past a naive "starts with a
        // slash ⇒ ours" check.
        let resolved = try HAImageURL.resolve(path: "//evil.example/steal", baseURL: local)
        #expect(resolved.url == url("http://evil.example/steal"))
        #expect(!resolved.authorize)
    }

    // MARK: - Redirects
    //
    // The first-hop check above is not the whole story: `URLSession` follows redirects itself and
    // re-sends the headers it was handed, so a `/api/camera_proxy/…` that 302s to a CDN would
    // carry the token to a host nothing ever evaluated. Both call sites ask the same predicate.

    @Test func authorizationDoesNotFollowARedirectOffTheOrigin() {
        #expect(!HAImageURL.mayCarryAuthorization(to: url("https://cdn.example.com/img"), origin: local))
        // Same host, different port — a different service on the same machine is still not us.
        #expect(!HAImageURL.mayCarryAuthorization(to: url("http://192.168.1.10:1400/img"), origin: local))
        // Same host, downgraded scheme: the token must not follow a redirect onto the wire in clear.
        #expect(!HAImageURL.mayCarryAuthorization(to: url("http://abc123.ui.nabu.casa/img"), origin: remote))
    }

    @Test func authorizationFollowsARedirectThatStaysOnTheOrigin() {
        // An internal redirect (a proxy rewriting a path) keeps the header — otherwise a
        // legitimately-redirecting deployment would see every image 401.
        #expect(HAImageURL.mayCarryAuthorization(to: url("http://192.168.1.10:8123/api/other"), origin: local))
    }

    // MARK: - Clean failures
    //
    // Every case below must produce a *named* refusal. The alternative — a plausible-looking URL
    // built from nonsense — is what renders an empty tile the caller believes is a working image.

    @Test func emptyPathIsItsOwnOutcome() {
        for blank in ["", "   ", "\n"] {
            #expect(throws: HAImageURLError.emptyPath) {
                try HAImageURL.resolve(path: blank, baseURL: local)
            }
        }
    }

    @Test func nonHTTPSchemesAreRejected() {
        // `data:` and `file:` would otherwise be fetched, and a custom scheme would be handed to
        // URLSession with an `Authorization` header attached.
        #expect(throws: HAImageURLError.unsupportedScheme("data")) {
            try HAImageURL.resolve(path: "data:image/png;base64,iVBORw0KGgo=", baseURL: local)
        }
        #expect(throws: HAImageURLError.unsupportedScheme("file")) {
            try HAImageURL.resolve(path: "file:///etc/passwd", baseURL: local)
        }
        #expect(throws: HAImageURLError.unsupportedScheme("javascript")) {
            try HAImageURL.resolve(path: "javascript:alert(1)", baseURL: local)
        }
    }

    @Test func unparseableReferenceFailsRatherThanProducingANonsenseURL() {
        // A host containing a space, and an unterminated IPv6 literal: `URL(string:relativeTo:)`
        // returns nil for both rather than guessing, and that nil must not be papered over.
        #expect(throws: HAImageURLError.unparseable("http://exa mple.com/x")) {
            try HAImageURL.resolve(path: "http://exa mple.com/x", baseURL: local)
        }
        #expect(throws: HAImageURLError.unparseable("http://[::1")) {
            try HAImageURL.resolve(path: "http://[::1", baseURL: local)
        }
        // Parses, but with an *empty* scheme — it is neither relative (so it never picks up the
        // base's scheme) nor http(s), and would reach URLSession as an unsupported request.
        #expect(throws: HAImageURLError.unsupportedScheme("")) {
            try HAImageURL.resolve(path: "://foo", baseURL: local)
        }
    }

    @Test func awkwardButLegalPathIsEncodedRatherThanRejected() {
        // Not every odd-looking reference is malformed: a space in the *path* is legal once
        // encoded, and rejecting it would drop images Home Assistant serves perfectly well. The
        // line is "could this be turned into a request at all", not "does it look tidy".
        let resolved = try? HAImageURL.resolve(path: "/api/camera_proxy/back garden.jpg", baseURL: local)
        #expect(resolved?.url.absoluteString == "http://192.168.1.10:8123/api/camera_proxy/back%20garden.jpg")
        #expect(resolved?.authorize == true)
    }

    @Test func hostlessHTTPReferenceIsRejected() {
        #expect(throws: HAImageURLError.self) {
            try HAImageURL.resolve(path: "http:///api/camera_proxy/camera.porch", baseURL: local)
        }
    }

    // MARK: - Cache keys

    @Test func cacheKeyDiffersWhenTheBaseURLChanges() throws {
        // The failover invalidation rule: bytes fetched from the local address must not be served
        // for the remote one. Same path, two hosts, two keys.
        let a = try HAImageURL.resolve(path: "/api/camera_proxy/camera.porch", baseURL: local)
        let b = try HAImageURL.resolve(path: "/api/camera_proxy/camera.porch", baseURL: remote)
        #expect(HAImageURL.cacheKey(for: a.url) != HAImageURL.cacheKey(for: b.url))
    }

    @Test func cacheKeyIsStableForTheSameResolvedURL() throws {
        let a = try HAImageURL.resolve(path: "/api/camera_proxy/camera.porch", baseURL: local)
        let b = try HAImageURL.resolve(path: "/api/camera_proxy/camera.porch", baseURL: local)
        #expect(HAImageURL.cacheKey(for: a.url) == HAImageURL.cacheKey(for: b.url))
    }

    @Test func cacheKeyIncludesTheQuery() {
        // `entity_picture`'s signed token changes when the artwork does; a key that ignored the
        // query would pin a media player to whatever was playing first.
        let first = HAImageURL.cacheKey(for: url("http://h:8123/api/media_player_proxy/x?token=aaa"))
        let second = HAImageURL.cacheKey(for: url("http://h:8123/api/media_player_proxy/x?token=bbb"))
        #expect(first != second)
    }

    @Test func cacheKeyDistinguishesPaths() {
        let porch = HAImageURL.cacheKey(for: url("http://h:8123/api/camera_proxy/camera.porch"))
        let hall = HAImageURL.cacheKey(for: url("http://h:8123/api/camera_proxy/camera.hall"))
        #expect(porch != hall)
    }

    @Test func cacheKeyTreatsDefaultPortsAsEquivalent() {
        // One host reached two ways is one cache entry, not two — the key shares its origin
        // definition with the connection layer rather than inventing a second one.
        #expect(HAImageURL.cacheKey(for: url("https://ha.example.com/api/x"))
                == HAImageURL.cacheKey(for: url("https://ha.example.com:443/api/x")))
    }
}
