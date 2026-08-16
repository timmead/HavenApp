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

    /// **A sheet holding a name and a state style commits once, not twice.**
    ///
    /// This is the whole reason `applyTileConfig` exists rather than `rename` followed by a
    /// state-style setter. Every write bumps the shared record's version, so two writes are two
    /// conflict windows and two chances for another phone in the household to read a half-applied
    /// edit — a device renamed but not restyled, or the reverse. Counting the frames is the only way
    /// to hold it: both spellings produce an identical final document, so no assertion about the
    /// *result* can tell them apart.
    ///
    /// Used to carry a third field, a size, proving the same invariant across three fields at once —
    /// `applyTileConfig` no longer takes one at all: per-entity sizing left the schema in Task 7,
    /// replaced by the subsection sheet's own single write (`aSubsectionSpanRoundTripsToTheWirePayload`
    /// below).
    @Test func aNameAndAStateStyleCommitInOneWrite() async throws {
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
                                                  stateStyle: .some(.label),
                                                  on: .overview)
        #expect(outcome == .written)

        let writes = await socket.frameTexts(ofType: "havenapp/config/set").compactMap(decode)
        #expect(writes.count == before + 1)

        let entities = (writes.last?["payload"] as? [String: Any])?["entities"] as? [String: Any]
        let entity = entities?["sensor.lr_temp"] as? [String: Any]
        #expect(entity?["name"] as? String == "Lounge")
        #expect(entity?["state_style"] as? String == "label")
    }

    /// **A drag writes only the surface it happened on, and leaves the other surface's list
    /// standing.**
    ///
    /// The regression this holds is the one design decision 9 was written for, and it is worth being
    /// exact about because the old shape looked fine from the surface you were on: a drag can only
    /// persist the ids it can *see*, so an overview drag storing the room's single shared list wrote
    /// a list with no room-detail-only tile in it — and `TileOrder.resolve`, correctly, then treated
    /// every demoted sensor as a newcomer and swept it to the end. Arranging the dashboard silently
    /// destroyed the arrangement of the room you had opened.
    ///
    /// Driven end to end rather than through the document alone: the write path is `HomeStore` →
    /// `HavenConfig.update` → the socket, and it is the *payload on the wire* that another phone in
    /// the household reads. Asserting on the frame is the only way to see what they would get.
    @Test func arrangingOneSurfaceLeavesTheOthersStoredOrderAlone() async throws {
        // A document that already holds a room-detail arrangement — the thing an overview drag used
        // to destroy. Version 4 so the write has a real base version to build on.
        let stored = #"""
        {"version":4,"payload":{"schema":1,"rooms":{"living":{
           "temperature":{"entity_id":"sensor.lr_temp","source":"state"},
           "order":{"room_detail":["sensor.demoted","sensor.lr_temp"]}}}},
         "updated":"2026-08-15T00:00:00+00:00","updated_by":"someone"}
        """#
        let (store, socket) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get":
                return #"{"id":\#(id),"type":"result","success":true,"result":\#(stored)}"#
            case "havenapp/config/set": return ok(id)
            default: return nil
            }
        }
        #expect(await store.setOrder(["sensor.lr_temp"], areaId: "living", on: .overview) == .written)

        let writes = await socket.frameTexts(ofType: "havenapp/config/set").compactMap(decode)
        let rooms = (writes.last?["payload"] as? [String: Any])?["rooms"] as? [String: Any]
        let order = (rooms?["living"] as? [String: Any])?["order"] as? [String: Any]
        #expect(order?["overview"] as? [String] == ["sensor.lr_temp"])
        // The assertion this test exists for.
        #expect(order?["room_detail"] as? [String] == ["sensor.demoted", "sensor.lr_temp"])
        // And the room's other keys are still there, as the merge discipline requires.
        #expect((rooms?["living"] as? [String: Any])?["temperature"] != nil)
    }

    /// Resetting an arrangement clears **both** surfaces in **one** write.
    ///
    /// Both, because an unset surface follows its sibling rather than taking the default — so
    /// clearing one alone would make it adopt the other's arrangement instead of forgetting one.
    /// One write, for the reason `applyTileConfig` exists: two would be two conflict windows and two
    /// chances for another phone to read a half-reset room.
    @Test func resettingAnArrangementClearsBothSurfacesInOneWrite() async throws {
        let stored = #"""
        {"version":4,"payload":{"schema":1,"rooms":{"living":{
           "temperature":{"entity_id":"sensor.lr_temp","source":"state"},
           "order":{"overview":["sensor.lr_temp"],"room_detail":["sensor.demoted"]}}}},
         "updated":"2026-08-15T00:00:00+00:00","updated_by":"someone"}
        """#
        let (store, socket) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get":
                return #"{"id":\#(id),"type":"result","success":true,"result":\#(stored)}"#
            case "havenapp/config/set": return ok(id)
            default: return nil
            }
        }
        let before = await socket.frameTexts(ofType: "havenapp/config/set").count
        #expect(await store.resetOrder(areaId: "living") == .written)

        let writes = await socket.frameTexts(ofType: "havenapp/config/set").compactMap(decode)
        #expect(writes.count == before + 1)
        let rooms = (writes.last?["payload"] as? [String: Any])?["rooms"] as? [String: Any]
        let living = rooms?["living"] as? [String: Any]
        // No `order` at all — not an empty object, which would be a husk the next read has to
        // tolerate for no reason.
        #expect(living?["order"] == nil)
        // The room record itself survives, because the nomination is still in it.
        #expect(living?["temperature"] != nil)
    }

}

// MARK: - The subsection sheet's write, and the global default

extension DashboardConfigWriteBackTests {

    /// **A chosen span reaches the wire under its kind and its surface, not an entity id.**
    /// Per-entity sizing left with `TileConfigView`'s size card (decision 5); this is what replaced
    /// it. **Updated with intent for decision 10** (subsection size became per-surface, from this
    /// task's own review — the schema section of the design doc): `size` was a flat string and is
    /// now an object keyed by surface, the same shape decision 9 gave `order`, so the assertion that
    /// matters moved from `subsections.<kind>.size` to `subsections.<kind>.size.<surface>`.
    @Test func aSubsectionSpanRoundTripsToTheWirePayload() async throws {
        let (store, socket) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get": return absent(id)
            case "havenapp/config/set": return ok(id)
            default: return nil
            }
        }
        let before = await socket.frameTexts(ofType: "havenapp/config/set").count

        let outcome = await store.applySubsectionConfig(
            .cameras, span: .some(TileSpan(columns: 4, rows: 2)), mode: nil, on: .overview)
        #expect(outcome == .written)

        let writes = await socket.frameTexts(ofType: "havenapp/config/set").compactMap(decode)
        #expect(writes.count == before + 1)
        let subsections = (writes.last?["payload"] as? [String: Any])?["subsections"] as? [String: Any]
        let cameras = subsections?["cameras"] as? [String: Any]
        #expect((cameras?["size"] as? [String: Any])?["overview"] as? String == "4x2")
        // `mode: nil` means "the sheet's mode control was untouched" — passing it through must not
        // manufacture a `mode` key next to the `size` one that *was* chosen.
        #expect(cameras?["mode"] == nil)
    }

    /// **Decision 10's merge discipline, driven end to end.** Writing a span on one surface must
    /// leave whatever the *other* surface already had standing — on the wire another phone in the
    /// household would actually read, not just in the in-memory document — mirrors
    /// `arrangingOneSurfaceLeavesTheOthersStoredOrderAlone` for order.
    @Test func aSubsectionSpanWriteLandsOnlyUnderItsOwnSurface() async throws {
        let stored = #"""
        {"version":4,"payload":{"schema":1,
           "rooms":{"living":{"temperature":{"entity_id":"sensor.lr_temp","source":"state"}}},
           "subsections":{"cameras":{"size":{"room_detail":"4x2"}}}},
         "updated":"2026-08-15T00:00:00+00:00","updated_by":"someone"}
        """#
        let (store, socket) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get":
                return #"{"id":\#(id),"type":"result","success":true,"result":\#(stored)}"#
            case "havenapp/config/set": return ok(id)
            default: return nil
            }
        }
        #expect(await store.applySubsectionConfig(
            .cameras, span: .some(TileSpan(columns: 2, rows: 2)), mode: nil, on: .overview) == .written)

        let writes = await socket.frameTexts(ofType: "havenapp/config/set").compactMap(decode)
        let subsections = (writes.last?["payload"] as? [String: Any])?["subsections"] as? [String: Any]
        let size = (subsections?["cameras"] as? [String: Any])?["size"] as? [String: Any]
        #expect(size?["overview"] as? String == "2x2")
        // The assertion this test exists for.
        #expect(size?["room_detail"] as? String == "4x2")
    }

    /// The write-side mirror of the test above: **clearing** one surface's span removes only that
    /// surface's key on the wire, leaving the other surface's stored value standing.
    @Test func clearingOneSurfacesSpanLeavesTheOtherStoredOnTheWire() async throws {
        let stored = #"""
        {"version":4,"payload":{"schema":1,
           "rooms":{"living":{"temperature":{"entity_id":"sensor.lr_temp","source":"state"}}},
           "subsections":{"cameras":{"size":{"overview":"2x2","room_detail":"4x2"}}}},
         "updated":"2026-08-15T00:00:00+00:00","updated_by":"someone"}
        """#
        let (store, socket) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get":
                return #"{"id":\#(id),"type":"result","success":true,"result":\#(stored)}"#
            case "havenapp/config/set": return ok(id)
            default: return nil
            }
        }
        #expect(await store.applySubsectionConfig(.cameras, span: .some(nil), mode: nil, on: .overview) == .written)

        let writes = await socket.frameTexts(ofType: "havenapp/config/set").compactMap(decode)
        let subsections = (writes.last?["payload"] as? [String: Any])?["subsections"] as? [String: Any]
        let size = (subsections?["cameras"] as? [String: Any])?["size"] as? [String: Any]
        #expect(size?["overview"] == nil)
        #expect(size?["room_detail"] as? String == "4x2")
    }

    /// **A chosen mode override reaches the wire the same way.** Span and mode are independent
    /// mutators sharing one kind-scoped object (`SubsectionConfig.storeSection`); this is the sibling
    /// of the span test above, exercised because the two write through the same `applySubsectionConfig`
    /// closure and one passing does not prove the other does. Mode stayed per-kind under decision
    /// 10 — only span became per-surface — so this one still needs no surface-keyed assertion, only
    /// the `on:` parameter every call site now carries.
    @Test func aSubsectionModeOverrideRoundTripsToTheWirePayload() async throws {
        let (store, socket) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get": return absent(id)
            case "havenapp/config/set": return ok(id)
            default: return nil
            }
        }
        let before = await socket.frameTexts(ofType: "havenapp/config/set").count

        let outcome = await store.applySubsectionConfig(.lights, span: nil, mode: .some(.wrap), on: .overview)
        #expect(outcome == .written)

        let writes = await socket.frameTexts(ofType: "havenapp/config/set").compactMap(decode)
        #expect(writes.count == before + 1)
        let subsections = (writes.last?["payload"] as? [String: Any])?["subsections"] as? [String: Any]
        let lights = subsections?["lights"] as? [String: Any]
        #expect(lights?["mode"] as? String == "wrap")
        #expect(lights?["size"] == nil)
    }

    /// **Passing no edits writes nothing** — the contract the deleted
    /// `aSheetThatChangedNothingButTheNameLeavesTheSizeAlone` held for `applyTileConfig`'s `size`,
    /// carried to `applySubsectionConfig`'s two settings.
    ///
    /// This is the store-level half of that contract, not the sheet's: `SubsectionConfigView`'s own
    /// dirty-check (`spanEdit`/`modeEdit`, deciding *whether* to pass `nil`) is private and reached
    /// by nothing here, the same as `TileConfigView.sizeEdit` always was. What this pins is that the
    /// store honours `nil` as "leave it alone" once the sheet has decided — `HavenConfig.update`'s
    /// own unchanged-guard would already refuse a document that came back equal, but this asserts it
    /// at the boundary this file otherwise tests every other mutator at, rather than trusting that
    /// guard by inference.
    @Test func passingNoEditsToTheSubsectionSheetsCommitWritesNothing() async throws {
        let (store, socket) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get": return absent(id)
            case "havenapp/config/set": return ok(id)
            default: return nil
            }
        }
        let before = await socket.frameTexts(ofType: "havenapp/config/set").count

        #expect(await store.applySubsectionConfig(.cameras, span: nil, mode: nil, on: .overview) == .unchanged)

        let writes = await socket.frameTexts(ofType: "havenapp/config/set").count
        #expect(writes == before)
    }

    /// **The overflow menu's global default lands under `display.mode`**, a sibling of
    /// `subsections` rather than a pseudo-kind inside it (schema section of the design doc) — the
    /// assertion that would catch a mutator wired to the wrong key.
    @Test func theHouseholdDefaultModeWritesUnderDisplayMode() async throws {
        let (store, socket) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get": return absent(id)
            case "havenapp/config/set": return ok(id)
            default: return nil
            }
        }
        let before = await socket.frameTexts(ofType: "havenapp/config/set").count

        #expect(await store.setDisplayMode(.wrap) == .written)

        let writes = await socket.frameTexts(ofType: "havenapp/config/set").compactMap(decode)
        #expect(writes.count == before + 1)
        let payload = writes.last?["payload"] as? [String: Any]
        #expect((payload?["display"] as? [String: Any])?["mode"] as? String == "wrap")
    }

    /// **Choosing "Household default" clears the override — the key leaves the wire, it does not
    /// turn into a null.** Booted from a document that already holds `subsections.lights.mode`,
    /// because writing `nil` over an *absent* record is a no-op (`HavenConfig.update` refuses to
    /// send an unchanged document at all) and would leave nothing on the wire to assert against.
    ///
    /// `subsections` here holds exactly one kind's exactly one key, so clearing it removes the whole
    /// subtree — the same "no empty husk" discipline `resettingAnArrangementClearsBothSurfacesInOneWrite`
    /// holds for `order`.
    @Test func householdDefaultWritesTheKeyAbsentRatherThanNull() async throws {
        let stored = #"""
        {"version":4,"payload":{"schema":1,
           "rooms":{"living":{"temperature":{"entity_id":"sensor.lr_temp","source":"state"}}},
           "subsections":{"lights":{"mode":"wrap"}}},
         "updated":"2026-08-15T00:00:00+00:00","updated_by":"someone"}
        """#
        let (store, socket) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get":
                return #"{"id":\#(id),"type":"result","success":true,"result":\#(stored)}"#
            case "havenapp/config/set": return ok(id)
            default: return nil
            }
        }
        let before = await socket.frameTexts(ofType: "havenapp/config/set").count

        let outcome = await store.applySubsectionConfig(.lights, span: nil, mode: .some(nil), on: .overview)
        #expect(outcome == .written)

        let writes = await socket.frameTexts(ofType: "havenapp/config/set").compactMap(decode)
        #expect(writes.count == before + 1)
        let payload = writes.last?["payload"] as? [String: Any]
        // Not `payload?["subsections"] as? [String: Any] == [:]` — an empty object is a husk every
        // future read has to tolerate for no reason. The key must be gone outright.
        #expect(payload?["subsections"] == nil)
        // And the room the document also carries survives the write untouched, as the merge
        // discipline requires of every mutator here.
        #expect((payload?["rooms"] as? [String: Any])?["living"] != nil)
    }
}
