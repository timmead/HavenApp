import Testing
import Foundation
@testable import HavenCore

@Test func authHandshakeSendsTokenAfterAuthRequired() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "tok")
    let texts = await conn.sentTexts()
    #expect(texts.contains { $0.contains("\"type\":\"auth\"") && $0.contains("tok") })
}

@Test func authInvalidThrows() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_invalid","error":{"code":"x","message":"bad"}}"#)
    await #expect(throws: (any Error).self) { try await client.authenticate(token: "tok") }
}

@Test func requestCorrelatesResultById() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    // When the client sends a command, reply with a success result for its id.
    await conn.setOnSend { data in
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let id = obj?["id"] as? Int, obj?["type"] as? String == "get_states" {
            await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":[1,2,3]}"#)
        }
    }
    let result = try await client.request { WSCommand.getStates(id: $0) }
    #expect(result.asArray?.count == 3)
}

/// Counts the pings a fake connection sees and lets a test wait for the Nth — so the heartbeat
/// tests are driven by observed traffic rather than by sleeping and hoping.
private actor PingWatcher {
    private(set) var pings = 0
    private var target = Int.max
    private var waiter: CheckedContinuation<Void, Never>?

    func recordPing() {
        pings += 1
        if pings >= target, let w = waiter { waiter = nil; w.resume() }
    }

    func wait(forPings n: Int) async {
        if pings >= n { return }
        target = n
        await withCheckedContinuation { waiter = $0 }
    }
}

/// **The regression test for "a heartbeat that cannot fail".**
///
/// The previous heartbeat awaited its ping with no deadline, so the *first* unanswered ping parked
/// the loop forever and no second ping was ever sent. Here every ping is answered, and the test
/// simply waits until three have been observed: if the loop can only ever send one, this never
/// returns and the time limit fails it.
@Test(.timeLimit(.minutes(1)))
func heartbeatKeepsPingingWhileThePongsComeBack() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    let watcher = PingWatcher()
    await conn.setOnSend { data in
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = obj?["id"] as? Int, obj?["type"] as? String == "ping" else { return }
        await watcher.recordPing()
        await conn.enqueueIncoming(#"{"id":\#(id),"type":"pong"}"#)
    }
    // A 1ms interval only makes the test quick; the generous ping timeout is what makes it
    // deterministic — a reply from an in-process fake cannot plausibly take five seconds, so no
    // miss can be recorded and the healthy path is the only one under test.
    await client.startHeartbeat(policy: HeartbeatPolicy(interval: .milliseconds(1), timeout: .seconds(5), tolerance: 2))
    await watcher.wait(forPings: 3)
    // A healthy connection is never torn down, however many pings go by.
    #expect(conn.closedFlag.closed == false)
    await client.disconnect()
}

/// **The half-open socket.** The connection stays open and the far end simply stops answering —
/// no socket error, so nothing else in the stack ever notices. The heartbeat must be what notices,
/// and it must route into the *existing* teardown path: closing the socket and finishing the event
/// stream, which is precisely what `HomeStore`'s subscription observes and turns into
/// `onDisconnected` → `AppModel.reconnectAfterConnectionLoss`.
@Test(.timeLimit(.minutes(1)))
func heartbeatTearsDownAConnectionThatStopsAnsweringPings() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    // The fake accepts pings and never replies — a socket that is up and answering nothing.
    await client.startHeartbeat(policy: HeartbeatPolicy(interval: .milliseconds(1), timeout: .milliseconds(20), tolerance: 2))
    // Ends only when `failAll` finishes the stream, i.e. when the client gave up on the connection.
    let events = await client.events
    for await _ in events {}
    #expect(conn.closedFlag.closed)
    let pings = await conn.sentTexts().filter { $0.contains("\"type\":\"ping\"") }
    // Exactly the tolerance: it kept pinging after the first miss (the old code could not) and
    // stopped at the second rather than pinging a dead socket forever.
    #expect(pings.count == 2)
}

/// A single missed pong is not a death sentence — the connection recovers and stays up.
@Test(.timeLimit(.minutes(1)))
func oneUnansweredPingFollowedByAPongDoesNotTearTheConnectionDown() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    let watcher = PingWatcher()
    await conn.setOnSend { data in
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = obj?["id"] as? Int, obj?["type"] as? String == "ping" else { return }
        await watcher.recordPing()
        // Swallow the first ping only; answer every one after it.
        if await watcher.pings > 1 { await conn.enqueueIncoming(#"{"id":\#(id),"type":"pong"}"#) }
    }
    await client.startHeartbeat(policy: HeartbeatPolicy(interval: .milliseconds(1), timeout: .milliseconds(20), tolerance: 2))
    await watcher.wait(forPings: 4)
    #expect(conn.closedFlag.closed == false)
    await client.disconnect()
}

/// The deadline that makes the above possible, on its own terms. `request` stays unbounded by
/// default (`AppModel`'s post-connect probes depend on that); this is the opt-in variant.
@Test(.timeLimit(.minutes(1)))
func aRequestWithATimeoutFailsWhenNoResultArrives() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    do {
        _ = try await client.request({ WSCommand.getStates(id: $0) }, timeout: .milliseconds(20))
        Issue.record("expected the request to time out")
    } catch let error as WSError {
        #expect(error.code == "timeout")
    }
    await client.disconnect()
}

/// A request made after the client gave up must fail rather than hang: the receive loop that would
/// have resolved it is gone, so nothing could ever answer. This matters now that the heartbeat can
/// tear a connection down while it still looks open to callers — `HomeStore`'s optimistic commands
/// land here routinely in the seconds before the reconnect replaces the client.
@Test(.timeLimit(.minutes(1)))
func aRequestAfterTeardownFailsImmediatelyRatherThanHangingForever() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await client.disconnect()
    await #expect(throws: WSError.self) { try await client.request { WSCommand.getStates(id: $0) } }
}

/// The same guarantee on the path that doesn't go through `disconnect()` — and the more common
/// one. A socket that simply drops takes the receive loop with it via `failAll`, with nobody
/// having asked for a teardown; a request issued afterwards must still fail rather than wait on a
/// continuation that no loop is left to resolve.
@Test(.timeLimit(.minutes(1)))
func aRequestAfterTheReceiveLoopDiedFailsImmediatelyRatherThanHangingForever() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    // Kills the receive loop the way a dropped socket does — no `disconnect()` involved.
    await conn.enqueueIncoming("not json at all")
    let events = await client.events
    for await _ in events {}   // returns once `failAll` has finished the stream
    await #expect(throws: WSError.self) { try await client.request { WSCommand.getStates(id: $0) } }
}

@Test func inFlightRequestFailsWhenReceiveLoopErrors() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    // Start a request that sends but whose result never arrives.
    let task = Task { try await client.request { WSCommand.getStates(id: $0) } }
    // Give the request a moment to register + send, then break the receive loop
    // with an undecodable frame so ServerFrame.decode throws -> failAll runs.
    try await Task.sleep(for: .milliseconds(50))
    await conn.enqueueIncoming("not json at all")
    await #expect(throws: (any Error).self) { _ = try await task.value }
}
