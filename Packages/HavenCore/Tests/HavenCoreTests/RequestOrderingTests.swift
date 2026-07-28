import Testing
import Foundation
@testable import HavenCore

/// **Home Assistant requires command ids to arrive in increasing order, and will close the
/// connection over it.**
///
/// From a real device log, on a connection that had just authenticated successfully:
///
/// ```
/// candidate ws://homeassistant.local:8123/api/websocket failed after
///   token=13ms socket=1ms auth=164ms total=446ms:
///   WSError(code: "id_reuse", message: "Identifier values have to increase.")
/// ```
///
/// `loadStructure()` fires its four registry queries concurrently with `async let` — the only
/// place in the app that has more than one request in flight — and `request` allocated the id
/// under actor isolation but handed the *send* to a separate unstructured `Task`. Four tasks then
/// raced to write, so the frames could leave in any order at all, and HA rejected the connection
/// the moment a lower id followed a higher one.
///
/// It is a race, which is why it presented as "connecting takes a few attempts": each round had a
/// decent chance of interleaving correctly, and the ones that did connected normally.
@Suite struct RequestOrderingTests {
    /// Records both the order frames were written in and **how many were in flight at once**, which
    /// is the property that actually matters.
    ///
    /// The order assertion alone is not enough to pin this: with a fake that completes its sends
    /// instantly, the frames come out ordered whether or not the client guarantees anything, so a
    /// test built only on order passes against the broken code. (It did — that was the first
    /// version of this test.) A transport with real latency is where the guarantee is either there
    /// or it isn't, so this one takes its time and counts overlap.
    private actor OverlapRecordingSocket: WebSocketConnection {
        private(set) var sentIds: [Int] = []
        private(set) var maxConcurrentSends = 0
        private var inFlight = 0
        private var incoming: [Data] = []
        private var waiters: [CheckedContinuation<Data, Error>] = []

        func connect() async throws {}
        nonisolated func close() {}

        func send(_ data: Data) async throws {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if obj["type"] as? String == "auth" { enqueue(#"{"type":"auth_ok"}"#); return }
            guard let id = obj["id"] as? Int else { return }

            inFlight += 1
            maxConcurrentSends = max(maxConcurrentSends, inFlight)
            sentIds.append(id)
            // Stands in for a real write actually taking time. Without it every send completes
            // before the next begins for reasons that have nothing to do with the client.
            try? await Task.sleep(for: .milliseconds(5))
            inFlight -= 1

            enqueue(#"{"id":\#(id),"type":"result","success":true,"result":[]}"#)
        }

        func receive() async throws -> Data {
            if !incoming.isEmpty { return incoming.removeFirst() }
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }

        func enqueue(_ text: String) {
            let data = Data(text.utf8)
            if !waiters.isEmpty { waiters.removeFirst().resume(returning: data) } else { incoming.append(data) }
        }
    }

    /// Eight concurrent requests — `loadStructure`'s four, with headroom.
    ///
    /// **The client must have at most one frame in flight.** That is the only thing that makes the
    /// wire order a property of the code rather than of the scheduler: `request` allocates its id
    /// under actor isolation, correctly ordered, and then hands the *write* to an unstructured
    /// `Task`. Nothing then relates the order those tasks reach the transport to the order their
    /// ids were taken, and Home Assistant closes the connection over exactly that.
    ///
    /// Asserted as overlap rather than as order because overlap is what the code either guarantees
    /// or doesn't. Order is what you *observe*, and on a fast fake you observe it being fine.
    @Test func onlyOneFrameIsInFlightSoIdsCannotOvertakeEachOther() async throws {
        let socket = OverlapRecordingSocket()
        await socket.enqueue(#"{"type":"auth_required"}"#)
        let client = HAWebSocketClient(connection: socket)
        try await client.authenticate(token: "t")

        await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try await client.request { WSCommand.getStates(id: $0) }
                }
            }
            while let _ = try? await group.next() {}
        }

        let overlap = await socket.maxConcurrentSends
        let ids = await socket.sentIds
        #expect(overlap == 1,
                "\(overlap) frames were being written at once — nothing keeps their ids in order")
        #expect(ids == ids.sorted(), "frames reached the wire as \(ids)")
    }
}
