import Foundation

public struct OAuthClient: Sendable {
    public static let clientId = "https://timmead.github.io/HavenApp/oauth/"
    public static let redirectURI = "havenapp://oauth/callback"
    public static let callbackScheme = "havenapp"
    public init() {}

    public func authorizeURL(baseURL: URL, state: String) -> URL {
        var c = URLComponents(url: baseURL.appendingPathComponent("auth/authorize"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "client_id", value: Self.clientId),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "state", value: state),
            .init(name: "response_type", value: "code"),
        ]
        // Ensure client_id/redirect encode as %2F etc.
        c.percentEncodedQuery = c.queryItems!.map {
            "\($0.name)=\($0.value!.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed)!)"
        }.joined(separator: "&")
        return c.url!
    }

    public func login(baseURL: URL, state: String = UUID().uuidString,
                      web: WebAuthSession, http: HTTPPoster) async throws -> HATokens {
        let callback = try await web.authenticate(url: authorizeURL(baseURL: baseURL, state: state),
                                                   callbackScheme: Self.callbackScheme)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw WSError(code: "oauth", message: "state mismatch")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw WSError(code: "oauth", message: "no code")
        }
        let data = try await http.post(baseURL.appendingPathComponent("auth/token"), form: [
            "grant_type": "authorization_code", "code": code, "client_id": Self.clientId,
        ])
        return try Self.parseTokens(data)
    }

    public func refresh(baseURL: URL, refreshToken: String, http: HTTPPoster) async throws -> HATokens {
        let data = try await http.post(baseURL.appendingPathComponent("auth/token"), form: [
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": Self.clientId,
        ])
        return try Self.parseTokens(data, fallbackRefresh: refreshToken)
    }

    static func parseTokens(_ data: Data, fallbackRefresh: String? = nil) throws -> HATokens {
        struct R: Decodable { let accessToken: String; let refreshToken: String?; let expiresIn: Double }
        let r = try HACoding.decoder.decode(R.self, from: data)
        return HATokens(accessToken: r.accessToken, refreshToken: r.refreshToken ?? fallbackRefresh,
                        expiresAt: Date().addingTimeInterval(r.expiresIn))
    }
}
