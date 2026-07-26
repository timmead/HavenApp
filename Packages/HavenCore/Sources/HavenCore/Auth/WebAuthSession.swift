import Foundation

public protocol WebAuthSession: Sendable {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

public protocol HTTPPoster: Sendable {
    func post(_ url: URL, form: [String: String]) async throws -> Data
}

public struct URLSessionHTTP: HTTPPoster {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func post(_ url: URL, form: [String: String]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed)!)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw WSError(code: "http", message: "token endpoint failed")
        }
        if (200..<300).contains(http.statusCode) { return data }
        // OAuth token endpoints use 400/401 for a rejected grant (expired/revoked refresh token,
        // bad code, etc.) — but per RFC 6749 the discriminator is the response BODY
        // (`{"error":"invalid_grant"}`), not the status code alone. A body-less or
        // differently-shaped 400/401 — e.g. a reverse proxy (Authelia, Cloudflare Access) whose
        // own session expired in front of Home Assistant — is a transient/infra failure, not
        // proof the OAuth grant itself is dead, and must not be treated as one: destroying the
        // stored session on a guess would be exactly the "signs out on a flaky moment" bug this
        // was meant to prevent. Erring toward "http" here just leaves the user retrying with a
        // working "Change server" escape hatch, which is the safer failure.
        if (http.statusCode == 400 || http.statusCode == 401), Self.bodyIndicatesInvalidGrant(data) {
            throw WSError(code: WSError.invalidGrantCode, message: "token endpoint rejected the request (\(http.statusCode))")
        }
        throw WSError(code: "http", message: "token endpoint failed (\(http.statusCode))")
    }

    private static func bodyIndicatesInvalidGrant(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? String else { return false }
        return error == "invalid_grant"
    }
}

extension CharacterSet {
    // Remove characters that must be percent-encoded in query parameter values:
    // &, =, + (form encoding), : and / (appear in URLs used as values like client_id)
    static let urlQueryValueAllowed: CharacterSet = {
        var cs = CharacterSet.urlQueryAllowed; cs.remove(charactersIn: "&=+:/"); return cs
    }()
}
