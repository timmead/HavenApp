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
