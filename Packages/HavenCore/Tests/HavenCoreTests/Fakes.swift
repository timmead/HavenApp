import Foundation
@testable import HavenCore

actor FakeWebSocketConnection: WebSocketConnection {
    private var incoming: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private(set) var sent: [Data] = []
    var onSend: (@Sendable (Data) async -> Void)?

    func connect() async throws {}
    nonisolated func close() {}
    func send(_ data: Data) async throws {
        sent.append(data)
        await onSend?(data)
    }
    func receive() async throws -> Data {
        if !incoming.isEmpty { return incoming.removeFirst() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    func enqueueIncoming(_ text: String) {
        let data = Data(text.utf8)
        if !waiters.isEmpty { waiters.removeFirst().resume(returning: data) }
        else { incoming.append(data) }
    }
    func sentTexts() -> [String] { sent.map { String(decoding: $0, as: UTF8.self) } }
}

extension FakeWebSocketConnection {
    func setOnSend(_ f: @escaping @Sendable (Data) async -> Void) { self.onSend = f }
}

struct FakeWebAuth: WebAuthSession {
    let returnURL: URL
    func authenticate(url: URL, callbackScheme: String) async throws -> URL { returnURL }
}

final class FakeHTTP: HTTPPoster, @unchecked Sendable {
    var response: String
    var error: Error?
    /// Optional artificial delay before responding — used to hold a call "in flight" long enough
    /// for concurrent callers to arrive and prove they coalesce onto it, rather than each firing
    /// their own request.
    var delay: Duration?
    private(set) var lastForm: [String: String]?
    private(set) var callCount = 0
    init(response: String) { self.response = response }
    func post(_ url: URL, form: [String: String]) async throws -> Data {
        callCount += 1
        lastForm = form
        if let delay { try? await Task.sleep(for: delay) }
        if let error { throw error }
        return Data(response.utf8)
    }
}

/// Simple in-memory `TokenStore` double for tests that don't want to touch the Keychain.
final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private(set) var saveCount = 0
    var current: HATokens?
    init(_ initial: HATokens? = nil) { self.current = initial }
    func save(_ tokens: HATokens) throws { current = tokens; saveCount += 1 }
    func load() -> HATokens? { current }
    func clear() { current = nil }
}
