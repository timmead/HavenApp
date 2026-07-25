import Foundation
import Security

public struct HATokens: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
    }
}

public protocol TokenStore: Sendable {
    func save(_ tokens: HATokens) throws
    func load() -> HATokens?
    func clear()
}

public struct KeychainTokenStore: TokenStore {
    private let account = "primary-home"
    private let service = "app.haven.tokens"
    public init() {}
    public func save(_ tokens: HATokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base; add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw WSError(code: "keychain", message: "save \(status)") }
    }
    public func load() -> HATokens? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(HATokens.self, from: data)
    }
    public func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}
