import Foundation

/// The two things an image request needs, read together at the moment the request is made.
public struct HAImageCredentials: Sendable, Equatable {
    /// The address the app is *currently* using to reach this Home Assistant instance.
    public let baseURL: URL
    public let accessToken: String

    public init(baseURL: URL, accessToken: String) {
        self.baseURL = baseURL
        self.accessToken = accessToken
    }
}

/// Supplies the base URL and access token for one image request.
///
/// The entire point of this protocol being `async` and per-request is that there is **no way to
/// hold on to what it returns**. `AuthenticatedImageLoader` stores a reference to the provider,
/// never a `HAImageCredentials`, so a base URL captured when a view was constructed cannot exist:
/// the app fails over between its local and remote addresses mid-session (see `AppModel.connect`),
/// and a captured URL means every image afterwards is fetched from a host we are no longer
/// talking to — which, since `AsyncImage`-style loading has no error surface, looks exactly like
/// a camera with nothing to show.
///
/// `TokenProvider` conforms below and is the only production implementation.
public protocol HAImageCredentialsProviding: Sendable {
    func imageCredentials() async throws -> HAImageCredentials
}

extension TokenProvider: HAImageCredentialsProviding {
    /// Both values come from the provider's live state — `currentBaseURL()` is whatever
    /// `setBaseURL` last pointed it at, and the token is refreshed on demand exactly as it is for
    /// the WebSocket. Nothing is cached here.
    public func imageCredentials() async throws -> HAImageCredentials {
        HAImageCredentials(baseURL: currentBaseURL(), accessToken: try await validAccessToken(now: Date()))
    }
}

/// Performs the actual GET. Abstracted so the loader is testable without a network — and, per the
/// project rule, without ever touching a live Home Assistant.
public protocol HAImageFetching: Sendable {
    /// - Parameter bearerToken: `nil` means *do not send an `Authorization` header* — the URL is
    ///   cross-origin (third-party artwork) and must not receive the user's token. Implementations
    ///   must honour that literally.
    /// - Returns: the response body and its HTTP status code. A non-2xx status is returned, not
    ///   thrown: the whole reason this feature exists is that a 401 must reach the caller as a
    ///   distinguishable outcome instead of vanishing into a placeholder.
    func fetch(_ url: URL, bearerToken: String?) async throws -> (Data, Int)
}

/// Why a load failed, for callers that need to show an error rather than a blank.
public enum ImageLoadFailure: Error, Sendable, Equatable {
    /// The reference could not be turned into a fetchable URL. Carries the specific reason;
    /// `.emptyPath` never appears here — the loader reports that as `.noImage`.
    case unresolvable(HAImageURLError)
    /// Home Assistant rejected the token for this image (401/403).
    ///
    /// Named separately from `httpStatus` because it is the failure this whole type exists for.
    /// A single `forceRefresh()`-and-retry here — mirroring `connect()`'s
    /// `didForceRefreshAfterAuthInvalid` — is the obvious next step and is deliberately **not**
    /// implemented yet: it is out of scope for the loader's first version, and leaving the case
    /// unnamed while adding the retry would hide whether the retry ever helped.
    case unauthorized
    case httpStatus(Int)
    /// The request never completed — timeout, host unreachable, TLS failure.
    ///
    /// Carries a deliberately coarse identifier (e.g. `"URLError -1001"`) rather than
    /// `localizedDescription` or a dumped error: `NSError`'s user info embeds the failing URL, and
    /// a resolved `entity_picture` URL carries a signed token in its query — so a "helpful"
    /// message here would be a credential in a log line.
    case transport(String)
    /// A 2xx with a zero-byte body. Treated as a failure on purpose: rendering nothing while
    /// reporting success is the exact confident-blank outcome this API exists to prevent.
    case emptyResponse
}

/// The result of one image load. Five outcomes, because collapsing any two of them reintroduces
/// the bug: a caller must be able to tell "this entity has no picture" from "the fetch failed"
/// from "there is no session to fetch with" — the first is a normal empty tile, the second is an
/// error state, and the third is a sign-in problem the user can act on.
public enum ImageLoadOutcome: Sendable, Equatable {
    case loaded(Data)
    /// No reference to load — not an error, just nothing to show.
    case noImage
    /// No usable session: `TokenProvider` could not produce a token at all. Carries its reason so
    /// the caller keeps the distinctions that type went to the trouble of making — in particular
    /// `.insecureTransportBlocked`, which is terminal, configuration-caused, and has user-facing
    /// copy in `TokenProviderError.message`; collapsing it into a generic failure is the exact
    /// trap documented on that case.
    case noCredentials(TokenProviderError)
    /// The request was cancelled — the view scrolled away, or the path changed mid-flight. Its own
    /// case so a scrolling dashboard doesn't flash error tiles for work it deliberately abandoned.
    case cancelled
    case failed(ImageLoadFailure)
}

/// What a view should put on screen for an outcome. The three states a renderer actually has —
/// picture, nothing, or something went wrong — with the five-way distinction above collapsed
/// exactly once, here, where it is tested.
///
/// It lives in HavenCore rather than in the SwiftUI wrapper because the collapse is a decision,
/// not glue: the entire point of the feature is that a failure never renders as an innocent
/// blank, and `App/` has no test target to hold that line in.
public enum ImageDisplayState: Sendable, Equatable {
    case image(Data)
    /// Nothing to show, and nothing wrong — this entity simply has no picture.
    case empty
    /// Show an error affordance. Deliberately covers `noCredentials` as well as `failed`: from the
    /// renderer's point of view "the session can't fetch it" and "the fetch failed" are both
    /// "we could not get this image", and the difference between them is for whoever acts on it
    /// (the sign-in flow), not for the tile.
    case failure
}

extension ImageLoadOutcome {
    /// The state to render, or `nil` for "change nothing".
    ///
    /// `nil` is only ever `.cancelled`, and it is the reason this is optional at all: a load
    /// abandoned because its tile scrolled away (or its path changed mid-flight) must leave
    /// whatever is on screen alone. Mapping it to `.failure` would make a fast scroll paint error
    /// icons over images that were never in trouble; mapping it to `.empty` would blank them.
    public var displayState: ImageDisplayState? {
        switch self {
        case .loaded(let data): return .image(data)
        case .noImage: return .empty
        case .cancelled: return nil
        case .noCredentials, .failed: return .failure
        }
    }
}

/// Loads images that live behind Home Assistant's authentication, with an in-memory cache.
///
/// SwiftUI's `AsyncImage` cannot attach an `Authorization` header, so pointed at
/// `/api/camera_proxy/<entity_id>` it silently 401s and renders its placeholder — a blank tile
/// indistinguishable from a working camera with nothing in front of it. This is its replacement,
/// and the difference that matters is `ImageLoadOutcome`: every failure is nameable by the caller.
///
/// An actor because the cache is shared by every tile on screen. Requests are **not** coalesced by
/// key: cancellation is per-caller here (a tile scrolling away cancels its own load), and sharing
/// one `Task` between callers would let the first one to disappear cancel the load still being
/// awaited by a second tile that is very much on screen.
public actor AuthenticatedImageLoader {
    /// Whether a cached copy may satisfy this request.
    public enum CachePolicy: Sendable {
        case useCache
        /// Skip the cache and replace what it holds. For the camera tiles' periodic refresh: the
        /// snapshot URL is stable but its *contents* are exactly what changes, so `useCache` would
        /// freeze the view on the first frame ever fetched.
        case reload
    }

    private let credentials: HAImageCredentialsProviding
    private let fetcher: HAImageFetching
    /// Cap on cached entries, evicted oldest-first. A bound rather than an LRU because the working
    /// set is "images currently on screen, plus recent ones", and the cost of an occasional
    /// re-fetch is one request — whereas an unbounded dictionary in a session that scrolls a large
    /// home for hours is a leak.
    private let cacheLimit: Int
    private var cache: [String: Data] = [:]
    private var insertionOrder: [String] = []

    public init(credentials: HAImageCredentialsProviding,
                fetcher: HAImageFetching = URLSessionImageFetcher(),
                cacheLimit: Int = 64) {
        self.credentials = credentials
        self.fetcher = fetcher
        self.cacheLimit = cacheLimit
    }

    /// Loads the image at `path`, which may be relative to the current base URL (the usual case:
    /// `entity_picture`, `/api/camera_proxy/…`) or already absolute.
    ///
    /// Returns rather than throws, because every one of the five outcomes is something the caller
    /// is expected to render differently — see `ImageLoadOutcome`.
    public func image(at path: String?, policy: CachePolicy = .useCache) async -> ImageLoadOutcome {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .noImage
        }
        if Task.isCancelled { return .cancelled }

        let credentials: HAImageCredentials
        do {
            credentials = try await self.credentials.imageCredentials()
        } catch let error as TokenProviderError {
            return .noCredentials(error)
        } catch is CancellationError {
            return .cancelled
        } catch {
            // A refresh that failed on the network (as opposed to being rejected) is a transient
            // load failure, not a dead session — the user is not signed out and a later attempt
            // may well work.
            return .failed(.transport(Self.transportIdentifier(error)))
        }

        let resolved: ResolvedImageURL
        do {
            resolved = try HAImageURL.resolve(path: path, baseURL: credentials.baseURL)
        } catch HAImageURLError.emptyPath {
            return .noImage
        } catch let error as HAImageURLError {
            return .failed(.unresolvable(error))
        } catch {
            return .failed(.unresolvable(.unparseable(path)))
        }

        let key = HAImageURL.cacheKey(for: resolved.url)
        if policy == .useCache, let cached = cache[key] { return .loaded(cached) }

        let body: Data
        let status: Int
        do {
            (body, status) = try await fetcher.fetch(resolved.url, bearerToken: resolved.authorize ? credentials.accessToken : nil)
        } catch is CancellationError {
            return .cancelled
        } catch let error as URLError where error.code == .cancelled {
            return .cancelled
        } catch {
            return .failed(.transport(Self.transportIdentifier(error)))
        }
        // Checked again after the await: a fetcher that ignores cooperative cancellation would
        // otherwise have its result cached and rendered for a view that is already gone.
        if Task.isCancelled { return .cancelled }

        guard (200..<300).contains(status) else {
            return .failed(status == 401 || status == 403 ? .unauthorized : .httpStatus(status))
        }
        guard !body.isEmpty else { return .failed(.emptyResponse) }

        // Only successes are cached, so a transient failure never blocks a later retry — the same
        // rule `HomeStore.loadHistory` follows for history series.
        store(body, forKey: key)
        return .loaded(body)
    }

    /// Drops everything cached. Called when the session ends; also the honest thing to do if an
    /// instance is ever switched under a live loader.
    public func clearCache() {
        cache.removeAll()
        insertionOrder.removeAll()
    }

    private func store(_ data: Data, forKey key: String) {
        if cache.updateValue(data, forKey: key) == nil {
            insertionOrder.append(key)
        }
        while insertionOrder.count > cacheLimit {
            cache.removeValue(forKey: insertionOrder.removeFirst())
        }
    }

    /// A stable, deliberately uninformative identifier for a failed request. See
    /// `ImageLoadFailure.transport` for why nothing richer is allowed here.
    private static func transportIdentifier(_ error: Error) -> String {
        if let urlError = error as? URLError { return "URLError \(urlError.code.rawValue)" }
        return String(describing: type(of: error))
    }
}

/// The production `HAImageFetching`: a plain authenticated GET.
public struct URLSessionImageFetcher: HAImageFetching {
    private let session: URLSession

    /// `nil` builds an **ephemeral** session, mirroring `URLSessionHTTP`. Ephemeral matters more
    /// here than there: these responses are fetched with the user's bearer token, and an ephemeral
    /// configuration keeps them (and any credentials or cookies picked up along the way) in memory
    /// only, never written to disk. `urlCache` is cleared outright so `AuthenticatedImageLoader`'s
    /// cache is the only one — two caches with different keying rules is how a `.reload` ends up
    /// quietly served from a stale copy anyway.
    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    public func fetch(_ url: URL, bearerToken: String?) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        // `URLSession` follows redirects on its own and will happily re-send the headers it was
        // given, so the same-origin decision made when this request was built covers only its
        // first hop: a `/api/camera_proxy/…` that 302s somewhere else would carry the token to a
        // host nothing ever evaluated. The delegate re-asks on every hop. It is per-request
        // because the origin the token belongs to is a property of this request, not of the
        // shared session.
        let (data, response) = try await session.data(
            for: request,
            delegate: bearerToken == nil ? nil : AuthorizationRedirectGuard(origin: url)
        )
        // A non-HTTP response can't have a status; reported as 0 rather than guessed at, so it
        // lands in `.httpStatus(0)` instead of masquerading as a success.
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Strips `Authorization` from any redirect that leaves the origin the token was minted for.
///
/// Immutable and single-use — one per request, holding only the origin — so it carries no state
/// between requests and needs no synchronization of its own.
private final class AuthorizationRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL

    init(origin: URL) {
        self.origin = origin
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        // The redirect is still followed — a Home Assistant deployment behind a proxy may
        // legitimately redirect its media URLs elsewhere, and refusing would turn working
        // artwork into an error. What does not follow it is the credential.
        guard let destination = request.url,
              !HAImageURL.mayCarryAuthorization(to: destination, origin: origin) else { return request }
        var stripped = request
        stripped.setValue(nil, forHTTPHeaderField: "Authorization")
        return stripped
    }
}
