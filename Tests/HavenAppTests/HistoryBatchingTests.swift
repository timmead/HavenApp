import Testing
import Foundation
import HavenCore
@testable import HavenApp

/// A socket that answers every `history/history_during_period` with rows for whatever it was asked
/// for, and remembers the frames so a test can count them.
private actor BatchSocket: WebSocketConnection {
    private var incoming: [String] = []
    private var sent: [String] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []

    func connect() async throws {}
    nonisolated func close() {}

    func send(_ data: Data) async throws {
        guard let text = String(data: data, encoding: .utf8) else { return }
        sent.append(text)
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = o["id"] as? Int else { return }
        if (o["type"] as? String) == "history/history_during_period" {
            let ids = (o["entity_ids"] as? [String]) ?? []
            let rows = ids.map { #""\#($0)":[{"s":"1","lu":1751328000.0}]"# }.joined(separator: ",")
            enqueue(#"{"id":\#(id),"type":"result","success":true,"result":{\#(rows)}}"#)
        } else {
            enqueue(#"{"id":\#(id),"type":"result","success":true,"result":{}}"#)
        }
    }

    func receive() async throws -> Data {
        if !incoming.isEmpty { return Data(incoming.removeFirst().utf8) }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func enqueue(_ text: String) {
        if let w = waiters.first { waiters.removeFirst(); w.resume(returning: Data(text.utf8)) }
        else { incoming.append(text) }
    }

    /// The `entity_ids` of each history frame sent, in order. `[[String]]` rather than the decoded
    /// frames because a dictionary of `Any` cannot cross an actor boundary — and the ids are the
    /// only part any of this needs.
    func historyBatches() -> [[String]] {
        sent.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { ($0["type"] as? String) == "history/history_during_period" }
            .map { ($0["entity_ids"] as? [String]) ?? [] }
    }
}

@Suite @MainActor struct HistoryBatchingTests {

    private func connected() async throws -> (HistoryCache, BatchSocket) {
        let socket = BatchSocket()
        let client = HAWebSocketClient(connection: socket)
        await socket.enqueue(#"{"type":"auth_required"}"#)
        await socket.enqueue(#"{"type":"auth_ok"}"#)
        try await client.authenticate(token: "t")
        let cache = HistoryCache()
        cache.attach(HomeConnection(client: client))
        return (cache, socket)
    }

    /// **The whole point, and the only thing that can show it.** Three sparklines asking on the same
    /// turn must produce *one* frame. The resulting cache is identical either way — three series,
    /// same values — so no assertion about the cache could tell one request from three. Only the
    /// frames can.
    @Test func severalTilesAskingAtOnceMakeOneRequest() async throws {
        let (cache, socket) = try await connected()

        // Three separate tasks, as three tiles' `.task` modifiers are — not three sequential
        // awaits, which would trivially batch by never overlapping.
        let a = Task { await cache.load("sensor.a", range: .day) }
        let b = Task { await cache.load("sensor.b", range: .day) }
        let c = Task { await cache.load("sensor.c", range: .day) }
        _ = await (a.value, b.value, c.value)

        let batches = await socket.historyBatches()
        #expect(batches.count == 1)
        #expect(batches.first?.sorted() == ["sensor.a", "sensor.b", "sensor.c"])
        // And every one of them got its series, not just the one that scheduled the flush.
        #expect(cache.series("sensor.a", .day) != nil)
        #expect(cache.series("sensor.b", .day) != nil)
        #expect(cache.series("sensor.c", .day) != nil)
    }

    /// A batch carries one start, one end and one attribute flag, so two ranges cannot share a
    /// frame — and must not be silently merged into whichever went first.
    @Test func differentRangesDoNotShareAFrame() async throws {
        let (cache, socket) = try await connected()

        let a = Task { await cache.load("sensor.a", range: .day) }
        let b = Task { await cache.load("sensor.b", range: .week) }
        _ = await (a.value, b.value)

        // `.week` uses statistics, so it sends a different command entirely — what matters is that
        // it did not join the day's frame and quietly receive a day's window.
        let batches = await socket.historyBatches()
        #expect(batches.count == 1)
        #expect(batches.first == ["sensor.a"])
    }

    /// A cached entry is not re-requested, and that guard has to survive batching — otherwise every
    /// re-appearance of a tile would put its entity back into a frame.
    @Test func anAlreadyCachedEntityIsNotAskedForAgain() async throws {
        let (cache, socket) = try await connected()
        await cache.load("sensor.a", range: .day)
        let first = await socket.historyBatches().count
        #expect(first == 1)

        await cache.load("sensor.a", range: .day)
        let second = await socket.historyBatches().count
        #expect(second == 1)
    }
}
