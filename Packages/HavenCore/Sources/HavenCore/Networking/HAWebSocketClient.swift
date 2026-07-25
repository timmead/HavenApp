import Foundation

public actor HAWebSocketClient {
    private let connection: WebSocketConnection
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var receiveLoop: Task<Void, Never>?
    private var eventContinuation: AsyncStream<ServerFrame>.Continuation?
    public let events: AsyncStream<ServerFrame>

    public init(connection: WebSocketConnection) {
        self.connection = connection
        var cont: AsyncStream<ServerFrame>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.eventContinuation = cont
    }

    public func authenticate(token: String) async throws {
        try await connection.connect()
        let first = try ServerFrame.decode(try await connection.receive())
        guard first == .authRequired else { throw WSError(code: "proto", message: "expected auth_required") }
        try await connection.send(WSCommand.auth(token: token))
        let second = try ServerFrame.decode(try await connection.receive())
        switch second {
        case .authOK: startReceiveLoop()
        case .authInvalid(let m): throw WSError(code: "auth_invalid", message: m)
        default: throw WSError(code: "proto", message: "expected auth_ok")
        }
    }

    public func request(_ make: (Int) -> Data) async throws -> JSONValue {
        let id = nextId; nextId += 1
        let data = make(id)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            Task {
                do { try await connection.send(data) }
                catch { if self.pending.removeValue(forKey: id) != nil { cont.resume(throwing: error) } }
            }
        }
    }

    private func startReceiveLoop() {
        guard receiveLoop == nil else { return }
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let data = try await self.connection.receive()
                    await self.handle(try ServerFrame.decode(data))
                } catch {
                    await self.failAll(with: error); return
                }
            }
        }
    }

    private func handle(_ frame: ServerFrame) {
        switch frame {
        case .result(let id, let success, let result, let error):
            guard let cont = pending.removeValue(forKey: id) else { return }
            if success { cont.resume(returning: result ?? .null) }
            else { cont.resume(throwing: error ?? WSError(code: "unknown", message: "failed")) }
        case .event, .pong:
            eventContinuation?.yield(frame)
        case .authRequired, .authOK, .authInvalid:
            break
        }
    }

    private func failAll(with error: Error) {
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
        eventContinuation?.finish()
    }

    public func disconnect() {
        receiveLoop?.cancel(); receiveLoop = nil
        connection.close()
        failAll(with: WSError(code: "closed", message: "disconnected"))
    }
}
