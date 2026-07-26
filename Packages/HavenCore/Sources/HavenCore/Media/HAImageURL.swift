import Foundation

/// Why an image reference could not be turned into something worth fetching. Every case is a
/// *clean* failure: the point of this type is that a nonsense input produces a named refusal
/// rather than a plausible-looking URL that 404s (or worse, resolves somewhere unintended) and
/// leaves the caller rendering an empty tile it believes is fine.
public enum HAImageURLError: Error, Sendable, Equatable {
    /// No reference at all — `entity_picture` absent, or present but blank. Distinct from the
    /// other two because it is not an error condition at the UI layer: the entity simply has no
    /// image, and `AuthenticatedImageLoader` turns this into `.noImage`, never `.failed`.
    case emptyPath
    /// The string could not be parsed as a URL even relative to the base — spaces, control
    /// characters, or anything else `URL(string:relativeTo:)` refuses under RFC 3986.
    case unparseable(String)
    /// Parsed, but not something to fetch over the network with a bearer token attached:
    /// `data:`, `file:`, `javascript:`, a custom scheme. Only `http`/`https` are accepted.
    case unsupportedScheme(String)
    /// Parsed as `http`/`https` but with no host — e.g. `http:///foo`. Nothing to connect to.
    case missingHost(String)
}

/// One image reference resolved against the base URL currently in use, plus the single decision
/// that cannot be made anywhere else: **whether the access token may be attached**.
public struct ResolvedImageURL: Sendable, Equatable {
    public let url: URL
    /// True only when `url` is same-origin with the base URL the caller resolved against.
    ///
    /// Home Assistant hands out `entity_picture` values that are frequently *absolute and
    /// foreign* — Spotify artwork on `i.scdn.co`, a Sonos speaker serving its own art from
    /// `http://192.168.1.30:1400/getaa?...`. Sending the Home Assistant bearer token to those
    /// hosts would hand a third party a credential for the user's home, so the token goes out
    /// only when we are talking to Home Assistant itself.
    ///
    /// This governs the *first* hop only. A redirect can move a request to another origin after
    /// this decision was made, which is why `URLSessionImageFetcher` re-asks
    /// `HAImageURL.mayCarryAuthorization(to:origin:)` on every redirect rather than trusting that
    /// the header it attached here is still going where it was meant to.
    public let authorize: Bool

    public init(url: URL, authorize: Bool) {
        self.url = url
        self.authorize = authorize
    }
}

/// Pure resolution and cache-key logic for images served by Home Assistant — album artwork
/// (`entity_picture`) and camera snapshots (`/api/camera_proxy/<entity_id>`).
///
/// It lives here, in HavenCore, rather than beside the SwiftUI view that consumes it because
/// `App/` has no test target: a same-origin check or a cache key that silently drifts is exactly
/// the kind of mistake that renders a confident blank tile instead of an error, which is this
/// project's recurring failure shape.
///
/// **Nothing here takes, stores, or is derived from an access token.** That is not a convention
/// to be remembered — no function below has a parameter it could be passed through.
public enum HAImageURL {
    /// Resolves one `entity_picture`/camera-proxy reference against the base URL **currently** in
    /// use, and decides whether the token may be attached to the result.
    ///
    /// - A relative path (`/api/camera_proxy/camera.porch`) resolves against `baseURL` and is
    ///   same-origin by construction, so it is authorized.
    /// - An already-absolute URL is passed through untouched, and is authorized only if it
    ///   happens to point back at `baseURL`'s origin.
    ///
    /// The caller must pass whatever base URL is live *at request time*. A consequence worth
    /// stating plainly: after a local↔remote failover, an absolute URL naming the *other* address
    /// (say a stored `http://192.168.1.10:8123/...` while we are now talking to Nabu Casa) is
    /// judged cross-origin and loses its `Authorization` header, so it fails visibly with a 401
    /// rather than shipping the token to a host this session is not talking to. A visible failure
    /// is the correct trade; a token sent to the wrong host is not recoverable.
    ///
    /// Origin comparison reuses `ConnectionEndpoint.normalizedKey` deliberately — it is the
    /// project's one definition of "the same endpoint" (scheme + host + default-aware port), and a
    /// second notion of it here would be free to drift from the one the connection layer uses.
    public static func resolve(path: String, baseURL: URL) throws -> ResolvedImageURL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HAImageURLError.emptyPath }
        // `URL(string:relativeTo:)` ignores the base for an already-absolute string, which is
        // exactly the pass-through behaviour wanted — and it resolves a protocol-relative
        // `//other.host/x` by inheriting only the *scheme*, so such a reference lands on a
        // different origin and is caught by the check below rather than being mistaken for ours.
        guard let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL else {
            throw HAImageURLError.unparseable(trimmed)
        }
        let scheme = resolved.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            throw HAImageURLError.unsupportedScheme(scheme)
        }
        guard let host = resolved.host(), !host.isEmpty else {
            throw HAImageURLError.missingHost(trimmed)
        }
        return ResolvedImageURL(url: resolved, authorize: mayCarryAuthorization(to: resolved, origin: baseURL))
    }

    /// Whether the access token may be sent to `url`, given that it is a credential for `origin`.
    ///
    /// The one place "same origin" is decided for this feature, asked twice: once when the request
    /// is built, and again for every redirect it is asked to follow. A redirect is the hole a
    /// first-hop-only check leaves open — `/api/camera_proxy/x` 302'ing to a host we never
    /// evaluated, with `Authorization` re-sent by a stock `URLSession` — and the answer must be
    /// the same both times, so both call sites go through this rather than through their own
    /// comparison.
    ///
    /// Note that scheme is part of `normalizedKey`, so an `https → http` downgrade for the same
    /// host is *not* the same origin, and the token does not follow it onto the wire in clear.
    public static func mayCarryAuthorization(to url: URL, origin: URL) -> Bool {
        ConnectionEndpoint.normalizedKey(url) == ConnectionEndpoint.normalizedKey(origin)
    }

    /// The in-memory cache key for an already-resolved absolute URL.
    ///
    /// Takes the resolved URL and nothing else — in particular **there is no token parameter to
    /// pass one through**, so "never key the cache on the token" is unexpressible rather than
    /// merely remembered.
    ///
    /// Two properties this must have, both of which are tested:
    /// - **The origin is part of the key.** After a local↔remote failover the same path resolves
    ///   against a different base URL, and the bytes fetched from the old host must not be served
    ///   for the new one — that is a cache serving a stale host's image with no way to tell.
    /// - **The query is part of the key.** Home Assistant's `entity_picture` carries a signed
    ///   `?token=…` that changes when the picture does, so dropping the query would pin a media
    ///   player's artwork to whatever was playing first.
    ///
    /// (The second point is also why nothing in this feature ever logs a resolved URL: the URL is
    /// itself credential-bearing.)
    public static func cacheKey(for url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let origin = ConnectionEndpoint.normalizedKey(url)
        let path = components?.percentEncodedPath ?? url.path
        guard let query = components?.percentEncodedQuery else { return origin + path }
        return "\(origin)\(path)?\(query)"
    }
}
