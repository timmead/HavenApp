import Testing
import Foundation
import HavenCore
@testable import HavenApp

/// A scriptable Home Assistant socket: answers each command with whatever the test says, and
/// records every frame the app sent.
///
/// Its own fake rather than HavenCore's: that one lives in the package's test target, which this
/// bundle does not link. Everything it needs (`WebSocketConnection`, `HAWebSocketClient`,
/// `HomeConnection`) is public API.
private actor ScriptedSocket: WebSocketConnection {
    private var incoming: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var sentTexts: [String] = []
    private var respond: (@Sendable (Int, String, [String: Any]) -> String?)?

    func connect() async throws {}
    nonisolated func close() {}

    func setResponder(_ f: @escaping @Sendable (Int, String, [String: Any]) -> String?) {
        respond = f
    }

    func send(_ data: Data) async throws {
        sentTexts.append(String(decoding: data, as: UTF8.self))
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? Int, let type = obj["type"] as? String else { return }
        if let body = respond?(id, type, obj) {
            enqueue(body.replacingOccurrences(of: "$ID", with: "\(id)"))
        }
    }

    func receive() async throws -> Data {
        if !incoming.isEmpty { return incoming.removeFirst() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func enqueue(_ text: String) {
        let data = Data(text.utf8)
        if !waiters.isEmpty { waiters.removeFirst().resume(returning: data) } else { incoming.append(data) }
    }

    /// The frames sent for `type`, as raw JSON text — `[[String: Any]]` is not `Sendable` and
    /// cannot leave the actor.
    func frameTexts(ofType type: String) -> [String] {
        sentTexts.filter { decode($0)?["type"] as? String == type }
    }
}

private let fixtureRegistry: [String: String] = [
    "config/floor_registry/list": #"[]"#,
    "config/area_registry/list": #"[{"area_id":"living","name":"Living","floor_id":null}]"#,
    "config/device_registry/list": #"[]"#,
    "config/entity_registry/list": #"[{"entity_id":"sensor.lr_temp","area_id":"living"}]"#,
]
private let fixtureStates =
    #"[{"entity_id":"sensor.lr_temp","state":"21.5","attributes":{"device_class":"temperature","unit_of_measurement":"°C"},"last_updated":"2026-07-27T00:00:00+00:00"}]"#

private func ok(_ id: Int) -> String {
    #"{"id":\#(id),"type":"result","success":true,"result":{"status":"ok","version":1}}"#
}
private func absent(_ id: Int) -> String {
    #"{"id":\#(id),"type":"result","success":true,"result":null}"#
}

private func decode(_ text: String) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
}

/// **The dashboard write-back, end to end.**
///
/// `HomeStore.loadDashboardConfig` / `persistProposedNominations` carry every decision about *when*
/// Haven writes to the shared household configuration: the base version a first write uses, the
/// refusal to write when nothing changed, the single conflict retry, and the two failures that must
/// never reach the user (not an admin, integration unreachable). None of that is exercised by a
/// `HomeStore` with no connection, so it is driven here through the real `bootstrap()`.
@Suite @MainActor struct DashboardConfigWriteBackTests {

    /// Boots a store against a socket that serves the fixture home, deferring to `config` for the
    /// two `havenapp/config/*` commands.
    private func boot(
        config: @escaping @Sendable (Int, String, [String: Any]) -> String?
    ) async throws -> (HomeStore, ScriptedSocket) {
        let socket = ScriptedSocket()
        await socket.setResponder { id, type, msg in
            if let body = fixtureRegistry[type] {
                return #"{"id":\#(id),"type":"result","success":true,"result":\#(body)}"#
            }
            switch type {
            case "get_states":
                return #"{"id":\#(id),"type":"result","success":true,"result":\#(fixtureStates)}"#
            case "subscribe_events":
                return #"{"id":\#(id),"type":"result","success":true,"result":null}"#
            default:
                return config(id, type, msg)
            }
        }
        await socket.enqueue(#"{"type":"auth_required"}"#)
        await socket.enqueue(#"{"type":"auth_ok"}"#)
        let client = HAWebSocketClient(connection: socket)
        try await client.authenticate(token: "t")

        let store = HomeStore()
        store.attach(HomeConnection(client: client))
        try await store.bootstrap()
        return (store, socket)
    }

    /// First run on a home with no dashboard yet: the auto-pick is proposed *and* written, and the
    /// write is based on version 0 — what the integration requires for a record that doesn't exist
    /// (`ConfigStore.async_set` compares against `existing.version if existing else 0`). Getting
    /// this wrong is silent: every first write would simply conflict forever.
    @Test func aFirstRunWritesTheProposedNominationAtVersionZero() async throws {
        let (store, socket) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get": return absent(id)
            case "havenapp/config/set": return ok(id)
            default: return nil
            }
        }
        #expect(store.environment["living"]?.temperature?.entityId == "sensor.lr_temp")

        let writes = await socket.frameTexts(ofType: "havenapp/config/set").compactMap(decode)
        #expect(writes.count == 1)
        #expect(writes.first?["base_version"] as? Int == 0)
        #expect(writes.first?["scope"] as? String == "shared")
        #expect(writes.first?["key"] as? String == "dashboard")
        let rooms = (writes.first?["payload"] as? [String: Any])?["rooms"] as? [String: Any]
        let living = rooms?["living"] as? [String: Any]
        #expect((living?["temperature"] as? [String: Any])?["entity_id"] as? String == "sensor.lr_temp")
    }

    /// The no-op guard. Once every room is nominated there is nothing new to say, and a write on
    /// each launch would churn the shared record's version and `updated_by` for nothing — making
    /// the audit trail useless and inviting conflicts between household devices that agree.
    @Test func aSecondRunWithEverythingAlreadyStoredWritesNothing() async throws {
        let stored = #"""
        {"version":4,"payload":{"schema":1,"rooms":{"living":{"temperature":{"entity_id":"sensor.lr_temp","source":"state"}}}},
         "updated":"2026-07-27T00:00:00+00:00","updated_by":"someone"}
        """#
        let (store, socket) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get":
                return #"{"id":\#(id),"type":"result","success":true,"result":\#(stored)}"#
            case "havenapp/config/set": return ok(id)
            default: return nil
            }
        }
        #expect(store.environment["living"]?.temperature?.entityId == "sensor.lr_temp")
        #expect(await socket.frameTexts(ofType: "havenapp/config/set").isEmpty)
    }

    /// Two admins' phones racing on first run. The loser reapplies onto what the winner wrote and
    /// retries **once**, at the version the conflict handed back — then stops. Both are proposing
    /// the same deterministic picks, so one retry is always enough; spinning on a pill would not be.
    @Test func aVersionConflictIsRetriedExactlyOnceAtTheReturnedVersion() async throws {
        let conflict = #"""
        {"status":"version_conflict",
         "current":{"version":9,"payload":{"schema":1,"rooms":{"hall":{"label":"Hall"}}},
                    "updated":"2026-07-27T00:00:00+00:00","updated_by":"other"}}
        """#
        let (_, socket) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get": return absent(id)
            case "havenapp/config/set":
                // Conflicts every time, so a retry loop would be unbounded if one existed.
                return #"{"id":\#(id),"type":"result","success":true,"result":\#(conflict)}"#
            default: return nil
            }
        }
        let writes = await socket.frameTexts(ofType: "havenapp/config/set").compactMap(decode)
        #expect(writes.count == 2)
        #expect(writes.first?["base_version"] as? Int == 0)
        #expect(writes.last?["base_version"] as? Int == 9)
        // The retry is built on the *winner's* document, so their room survives ours.
        let payload = writes.last?["payload"] as? [String: Any]
        let rooms = payload?["rooms"] as? [String: Any]
        #expect(rooms?["hall"] != nil)
        #expect(rooms?["living"] != nil)
    }

    /// A household member who is not an HA admin. The integration refuses the write, and that is
    /// the expected steady state rather than a fault: it must not throw out of `bootstrap()`, and
    /// the pills must still be there, because a proposal renders whether or not it was persisted.
    @Test func aNonAdminStillGetsPillsAndNoError() async throws {
        let (store, socket) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get": return absent(id)
            case "havenapp/config/set":
                return #"{"id":\#(id),"type":"result","success":false,"error":{"code":"not_authorized","message":"not authorized for this scope"}}"#
            default: return nil
            }
        }
        #expect(store.environment["living"]?.temperature?.entityId == "sensor.lr_temp")
        #expect(store.rooms().first?.headerSensors.count == 1)
        #expect(await socket.frameTexts(ofType: "havenapp/config/set").count == 1)
    }

    /// An unreachable or not-yet-installed integration. A dashboard that fails to load must not
    /// take the *home* down with it — `bootstrap()` is `throws`, so letting this out would fail the
    /// whole session over a pill. The rooms, their tiles and the proposed pills all still render.
    @Test func anUnreadableConfigDoesNotFailTheSession() async throws {
        let (store, socket) = try await boot { id, type, _ in
            guard type == "havenapp/config/get" else { return nil }
            return #"{"id":\#(id),"type":"result","success":false,"error":{"code":"unknown_command","message":"nope"}}"#
        }
        #expect(store.rooms().count == 1)
        #expect(store.environment["living"]?.temperature?.entityId == "sensor.lr_temp")
        // Nothing is written over a document we could not read — that would overwrite it.
        #expect(await socket.frameTexts(ofType: "havenapp/config/set").isEmpty)
    }

    /// A document from a newer app build is readable but never writable: this build cannot know
    /// what invariants the newer schema relies on.
    @Test func aNewerSchemaIsNeverWrittenTo() async throws {
        let stored = #"""
        {"version":2,"payload":{"schema":99,"rooms":{}},
         "updated":"2026-07-27T00:00:00+00:00","updated_by":"future"}
        """#
        let (store, socket) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get":
                return #"{"id":\#(id),"type":"result","success":true,"result":\#(stored)}"#
            case "havenapp/config/set": return ok(id)
            default: return nil
            }
        }
        #expect(store.environment["living"]?.temperature?.entityId == "sensor.lr_temp")
        #expect(await socket.frameTexts(ofType: "havenapp/config/set").isEmpty)
    }
}

// MARK: - The configuration sheet's single write

extension DashboardConfigWriteBackTests {

    /// **A sheet holding a name and a size commits once, not twice.**
    ///
    /// This is the whole reason `applyTileConfig` exists rather than `rename` followed by a size
    /// setter. Every write bumps the shared record's version, so two writes are two conflict windows
    /// and two chances for another phone in the household to read a half-applied edit — a device
    /// renamed but not resized, or the reverse. Counting the frames is the only way to hold it: both
    /// spellings produce an identical final document, so no assertion about the *result* can tell
    /// them apart.
    @Test func aNameAndASizeCommitInOneWrite() async throws {
        let (store, socket) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get": return absent(id)
            case "havenapp/config/set": return ok(id)
            default: return nil
            }
        }
        // Bootstrap writes the auto-picked nominations; the sheet's write is the one after it.
        let before = await socket.frameTexts(ofType: "havenapp/config/set").count

        let outcome = await store.applyTileConfig("sensor.lr_temp", name: "Lounge",
                                                  size: .some(TileSpan(columns: 2, rows: 1)),
                                                  on: .overview)
        #expect(outcome == .written)

        let writes = await socket.frameTexts(ofType: "havenapp/config/set").compactMap(decode)
        #expect(writes.count == before + 1)

        let entities = (writes.last?["payload"] as? [String: Any])?["entities"] as? [String: Any]
        let entity = entities?["sensor.lr_temp"] as? [String: Any]
        #expect(entity?["name"] as? String == "Lounge")
        #expect((entity?["sizes"] as? [String: Any])?["overview"] as? String == "2x1")
    }

    /// Choosing the size a tile already had is not an edit, and must not write. The sheet decides
    /// this — see `TileConfigView.sizeEdit` — but the store must not write for a nil size either,
    /// or every Done on an unresized tile would churn the household's document.
    @Test func aSheetThatChangedNothingButTheNameLeavesTheSizeAlone() async throws {
        let (store, socket) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get": return absent(id)
            case "havenapp/config/set": return ok(id)
            default: return nil
            }
        }
        _ = await store.applyTileConfig("sensor.lr_temp", name: "Lounge", size: nil, on: .overview)

        let writes = await socket.frameTexts(ofType: "havenapp/config/set").compactMap(decode)
        let entities = (writes.last?["payload"] as? [String: Any])?["entities"] as? [String: Any]
        let entity = entities?["sensor.lr_temp"] as? [String: Any]
        #expect(entity?["name"] as? String == "Lounge")
        #expect(entity?["sizes"] == nil)
    }
}
