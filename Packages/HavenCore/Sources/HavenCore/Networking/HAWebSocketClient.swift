import Foundation

public actor HAWebSocketClient {
    private let connection: WebSocketConnection
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var receiveLoop: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var eventContinuation: AsyncStream<ServerFrame>.Continuation?
    /// Set once this client has given up on its connection — by `failAll`, so it covers both the
    /// deliberate `teardown` and a receive loop dying on a dropped socket. A client is one-shot —
    /// `AppModel` builds a fresh one per connection attempt — so once the receive loop is gone
    /// there is nothing left that could ever resolve a newly-registered request, and registering
    /// one anyway is a permanent hang for that caller.
    ///
    /// Newly relevant because of the heartbeat teardown below: a half-open socket is now
    /// torn down *while it still looks open to every caller*, so `HomeStore`'s optimistic commands
    /// routinely land on a dead client in the seconds before the reconnect replaces it. Over
    /// `NWConnection` a send on a cancelled connection errors out, which resolves them; over a
    /// transport whose `send` succeeds regardless (the test fake, and any real one that buffers)
    /// it would not.
    private var isClosed = false
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
        case .authInvalid(let m): throw WSError(code: WSError.authInvalidCode, message: m)
        default: throw WSError(code: "proto", message: "expected auth_ok")
        }
    }

    /// Sends a command and waits — **without a deadline** — for the result with the matching id.
    ///
    /// Deliberately unbounded, and it must stay that way: `AppModel`'s post-`ready` probes
    /// (`get_config`, `cloud/status`) run over a connection the user is already using, and an
    /// instance that simply never answers one of them must not become a failed connection. The
    /// bounded variant below exists for the heartbeat, which is the one caller for which "no
    /// answer" *is* the signal.
    public func request(_ make: (Int) -> Data) async throws -> JSONValue {
        try await request(make, timeout: nil)
    }

    /// - Parameter timeout: if non-nil, how long to wait for the matching result before failing
    ///   the call with a `timeout` `WSError`. The pending continuation is removed from `pending`
    ///   under actor isolation before being resumed, so a timeout and a real result racing each
    ///   other resolve it exactly once — whichever of them takes it out of the dictionary first.
    func request(_ make: (Int) -> Data, timeout: Duration?) async throws -> JSONValue {
        guard !isClosed else { throw WSError(code: "closed", message: "client is disconnected") }
        let id = nextId; nextId += 1
        let data = make(id)
        // Started before the continuation is registered, which is safe: everything from here to
        // `pending[id] = cont` runs synchronously on the actor with no suspension point, so this
        // task cannot get onto the actor to expire an id that isn't registered yet.
        let expiry: Task<Void, Never>? = timeout.map { limit in
            Task { [weak self] in
                do { try await Task.sleep(for: limit) } catch { return }   // cancelled: result won
                await self?.expire(id: id, after: limit)
            }
        }
        defer { expiry?.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            Task {
                do { try await connection.send(data) }
                catch { if self.pending.removeValue(forKey: id) != nil { cont.resume(throwing: error) } }
            }
        }
    }

    /// Fails the request with `id` because its deadline passed. A no-op if the result (or
    /// `failAll`) already claimed it.
    private func expire(id: Int, after limit: Duration) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        cont.resume(throwing: WSError(code: "timeout", message: "no response within \(limit)"))
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
                    // A cancelled receive is not a dropped connection — it is `disconnect()`
                    // tearing this loop down, and `disconnect()` has already run `failAll` and
                    // finished the event stream. Now that cancellation actually propagates into
                    // `NWWebSocketConnection.receive()` (it previously didn't, so this arrived only
                    // as a socket error), treating it as a drop would finish the event stream a
                    // second time *after* the deliberate teardown, which `HomeStore.isResetting`
                    // exists to keep from being read as "the socket died on its own".
                    if Task.isCancelled { return }
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
        case .pong(let id):
            if let cont = pending.removeValue(forKey: id) { cont.resume(returning: .null) }
            eventContinuation?.yield(frame)
        case .event:
            eventContinuation?.yield(frame)
        case .authRequired, .authOK, .authInvalid:
            break
        }
    }

    /// Resolves every waiting caller with `error` and ends the event stream — which is what
    /// `HomeStore`'s subscription task observes, and therefore how `onDisconnected` (and so
    /// `AppModel.reconnectAfterConnectionLoss`) is reached. Every path that gives up on this
    /// connection goes through here.
    ///
    /// **No race with `request` registering afterwards, and the reason is worth stating** because
    /// the shape looks like one. `request` allocates the id and does `pending[id] = cont` inside
    /// the `withCheckedThrowingContinuation` body — synchronously, on the actor, with no `await`
    /// anywhere between — so a request can never insert into `pending` *after* this ran while
    /// believing it inserted before. The unstructured `Task` it spawns only *sends*; the sole way
    /// it touches `pending` is `removeValue(forKey:) != nil`, which is also what stops it
    /// double-resuming a continuation this function already claimed. Actor isolation and that
    /// guard together, not isolation alone.
    private func failAll(with error: Error) {
        isClosed = true
        // Marked here rather than in `teardown` because the receive loop's error branch reaches
        // *this* function directly: after a genuine drop (Wi-Fi lost, HA restarted, an undecodable
        // frame) the loop that resolves results is gone even though nobody called `disconnect()`.
        // A request registered after that would wait on a continuation nothing can ever resume.
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
        eventContinuation?.finish()
    }

    /// Pings on a schedule and — this is the part that makes it a heartbeat rather than an
    /// ornament — **treats a run of unanswered pings as a dead connection** and tears the client
    /// down through the ordinary failure path.
    ///
    /// The failure it exists for is the half-open socket: the phone changes network, a NAT table
    /// expires, or Home Assistant hangs, and the TCP connection stays up while nothing comes back
    /// over it. No socket error is ever raised, so the receive loop never throws and nothing
    /// reaches `onDisconnected`; the dashboard renders stale state (including lock status)
    /// indefinitely while every command silently no-ops. The previous implementation made this
    /// *worse* than no heartbeat at all: `request` had no deadline, so the very first unanswered
    /// ping parked this task on an `await` that could never resolve, and no second ping was ever
    /// sent.
    ///
    /// Timing and the liveness rule live in `HeartbeatPolicy`; see it for the numbers and the ~20s
    /// worst-case detection they imply. This function is only the clock.
    public func startHeartbeat(policy: HeartbeatPolicy = HeartbeatPolicy()) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            var monitor = HeartbeatMonitor(policy: policy)
            while !Task.isCancelled {
                do { try await Task.sleep(for: monitor.delayBeforeNextPing) } catch { return }
                guard let self else { return }
                let outcome: PingOutcome
                do {
                    _ = try await self.request({ WSCommand.ping(id: $0) }, timeout: policy.timeout)
                    outcome = .pong
                } catch {
                    // Any failure, not just the timeout: a send error or a `failAll` resolving the
                    // ping both mean this ping did not prove the connection is alive.
                    outcome = .missed
                }
                // Checked after the await: `disconnect()` cancels this task while a ping may be in
                // flight, and that ping's induced failure must not be read as the connection dying
                // on its own.
                if Task.isCancelled { return }
                guard monitor.record(outcome) else { continue }
                havenCoreLog.error("heartbeat: \(policy.tolerance, privacy: .public) consecutive pings unanswered within \(String(describing: policy.timeout), privacy: .public) each — treating the connection as dead")
                await self.teardown(reason: WSError(code: "heartbeat", message: "connection stopped answering pings"))
                return
            }
        }
    }

    public func disconnect() {
        teardown(reason: WSError(code: "closed", message: "disconnected"))
    }

    /// Cancels both loops, closes the socket, and fails everything waiting on it.
    ///
    /// Shared by the deliberate `disconnect()` and by the heartbeat's own verdict on purpose:
    /// routing a dead heartbeat into a second, parallel notification path would leave two ways for
    /// the app to learn the connection is gone, only one of which the reconnect is wired to.
    private func teardown(reason: Error) {
        receiveLoop?.cancel(); receiveLoop = nil
        heartbeat?.cancel(); heartbeat = nil
        connection.close()
        failAll(with: reason)
    }
}
