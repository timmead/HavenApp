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
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WSError(code: "http", message: "token endpoint failed")
        }
        return data
    }
}

extension CharacterSet {
    // Remove characters that must be percent-encoded in query parameter values:
    // &, =, + (form encoding), : and / (appear in URLs used as values like client_id)
    static let urlQueryValueAllowed: CharacterSet = {
        var cs = CharacterSet.urlQueryAllowed; cs.remove(charactersIn: "&=+:/"); return cs
    }()
}
