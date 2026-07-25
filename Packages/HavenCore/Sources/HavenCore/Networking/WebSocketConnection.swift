import Foundation

public protocol WebSocketConnection: Sendable {
    func connect() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

@available(iOS 13, macOS 10.15, *)
public final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let url: URL
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    public init(url: URL, session: URLSession? = nil) {
        self.url = url
        // A dedicated session (not URLSession.shared) is the recommended pattern for
        // WebSocket tasks and avoids some shared-session quirks.
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.waitsForConnectivity = true
            config.timeoutIntervalForRequest = 15
            self.session = URLSession(configuration: config)
        }
        self.task = self.session.webSocketTask(with: url)
    }
    public func connect() async throws { task.resume() }
    public func send(_ data: Data) async throws { try await task.send(.data(data)) }
    public func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let d): return d
        case .string(let s): return Data(s.utf8)
        @unknown default: return Data()
        }
    }
    public func close() { task.cancel(with: .goingAway, reason: nil) }
}
