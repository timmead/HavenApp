import Testing
import Foundation
@testable import HavenCore

private func json(_ text: String) -> JSONValue {
    try! HACoding.decoder.decode(JSONValue.self, from: Data(text.utf8))
}

// MARK: - The forward-compatibility guarantee

/// The property this whole type exists for, and the one most likely to be quietly broken by a
/// later refactor into a `Codable` struct: a write must preserve every key this build has never
/// heard of, both at the top level and inside a room. Without it, an older phone in the household
/// strips a newer phone's dashboard on its next routine write — invisibly, until someone notices
/// their layout has reverted.
///
/// Asserted on the parsed `JSONValue`, never on serialized bytes: `JSONSerialization` key ordering
/// and int/double normalisation would both make a byte comparison fail for reasons that are not
/// bugs in the merge, and a flaky test guarding the most important invariant here gets deleted
/// rather than fixed.
@Test func mergePreservesEveryUnknownKey() {
    let original = json(#"""
    { "schema": 1,
      "tilePositions": { "living": [1, 2, 3] },
      "somethingAFutureBuildAdded": { "nested": { "deep": true } },
      "rooms": {
        "living": { "temperature": {"entity_id":"sensor.old","source":"state"},
                    "label": "The Lounge",
                    "tiles": ["light.a", "light.b"] },
        "kitchen": { "label": "Kitchen", "tiles": [] } } }
    """#)

    let merged = DashboardDocument(raw: original).merging([
        "living": RoomEnvironmentOverride(
            temperature: UpliftedSensor(role: .temperature, entityId: "sensor.new", source: .state))
    ])
    let root = merged.raw.asObject

    // Untouched top-level keys survive, values and all.
    #expect(root?["tilePositions"] == original.asObject?["tilePositions"])
    #expect(root?["somethingAFutureBuildAdded"] == original.asObject?["somethingAFutureBuildAdded"])

    // Untouched keys *inside* the room we did write survive.
    let living = root?["rooms"]?.asObject?["living"]?.asObject
    #expect(living?["label"]?.asString == "The Lounge")
    #expect(living?["tiles"] == json(#"["light.a","light.b"]"#))
    #expect(living?["temperature"]?.asObject?["entity_id"]?.asString == "sensor.new")

    // A room we didn't mention is untouched entirely.
    #expect(root?["rooms"]?.asObject?["kitchen"] == original.asObject?["rooms"]?.asObject?["kitchen"])
}

/// Merging a room that isn't in the document yet must create it without disturbing its siblings.
@Test func mergeAddsANewRoomWithoutTouchingOthers() {
    let original = json(#"{"schema":1,"rooms":{"kitchen":{"label":"Kitchen"}}}"#)
    let merged = DashboardDocument(raw: original).merging([
        "study": RoomEnvironmentOverride(
            humidity: UpliftedSensor(role: .humidity, entityId: "sensor.s", source: .state))
    ])
    let rooms = merged.raw.asObject?["rooms"]?.asObject
    #expect(rooms?["kitchen"] == original.asObject?["rooms"]?.asObject?["kitchen"])
    #expect(rooms?["study"]?.asObject?["humidity"]?.asObject?["entity_id"]?.asString == "sensor.s")
}

/// Writing only temperature must not clear a humidity nomination already stored for that room.
@Test func mergeLeavesTheOtherRoleAlone() {
    let original = json(#"""
    {"schema":1,"rooms":{"living":{"humidity":{"entity_id":"sensor.h","source":"state"}}}}
    """#)
    let merged = DashboardDocument(raw: original).merging([
        "living": RoomEnvironmentOverride(
            temperature: UpliftedSensor(role: .temperature, entityId: "sensor.t", source: .state))
    ])
    let living = merged.raw.asObject?["rooms"]?.asObject?["living"]?.asObject
    #expect(living?["humidity"]?.asObject?["entity_id"]?.asString == "sensor.h")
    #expect(living?["temperature"]?.asObject?["entity_id"]?.asString == "sensor.t")
}

@Test func mergingNothingIsAnExactNoOp() {
    let original = json(#"{"schema":1,"rooms":{"living":{"label":"x"}}}"#)
    let doc = DashboardDocument(raw: original)
    #expect(doc.merging([:]) == doc)
}

// MARK: - Envelope

@Test func absentPayloadMintsAnEmptyCurrentSchemaDocument() {
    let doc = DashboardDocument(raw: nil)
    #expect(doc.declaredSchema == DashboardDocument.schema)
    #expect(doc.nominations.isEmpty)
    #expect(doc.isWritable)
}

/// A payload that isn't a JSON object at all is replaced rather than merged into. Safe in a way
/// replacing an unknown-but-well-formed document would not be: no version of Haven has ever
/// written a non-object here, so no real data is being discarded.
@Test func nonObjectPayloadIsReplaced() {
    #expect(DashboardDocument(raw: .string("nonsense")).declaredSchema == DashboardDocument.schema)
}

/// A document from a newer build is readable but never writable — this build cannot know what
/// invariants the newer schema relies on, and the merge protects unknown *keys*, not unknown
/// *semantics*.
@Test func newerSchemaIsReadableButNotWritable() {
    let doc = DashboardDocument(raw: json(#"""
    {"schema":2,"rooms":{"living":{"temperature":{"entity_id":"sensor.t","source":"state"}}}}
    """#))
    #expect(!doc.isWritable)
    #expect(doc.nominations["living"]?.temperature?.entityId == "sensor.t")
}

// MARK: - One nomination's wire shape

@Test func bothSourceFormsRoundTrip() {
    let sensors = RoomEnvironmentOverride(
        temperature: UpliftedSensor(role: .temperature, entityId: "climate.lr",
                                    source: .attribute("current_temperature")),
        humidity: UpliftedSensor(role: .humidity, entityId: "sensor.h", source: .state))
    let doc = DashboardDocument().merging(["living": sensors])
    #expect(doc.nominations["living"] == sensors)

    // The wire shape itself, so a later encoder change can't silently rename a key that a
    // configuration UX (or another client) is reading.
    let temp = doc.raw.asObject?["rooms"]?.asObject?["living"]?.asObject?["temperature"]?.asObject
    #expect(temp?["entity_id"]?.asString == "climate.lr")
    #expect(temp?["source"]?.asString == "attribute")
    #expect(temp?["attribute"]?.asString == "current_temperature")
}

/// A document written before `source` existed recorded only state reads, so an absent `source` must
/// decode as `.state` rather than being discarded.
@Test func absentSourceDecodesAsState() {
    let doc = DashboardDocument(raw: json(#"{"rooms":{"living":{"temperature":{"entity_id":"sensor.t"}}}}"#))
    #expect(doc.nominations["living"]?.temperature?.source == .state)
}

/// An attribute source with no attribute name has nothing to read. Dropping it re-proposes the
/// room, which is recoverable; keeping it would manufacture a permanent "—".
@Test func malformedNominationsAreDroppedNotFatal() {
    let doc = DashboardDocument(raw: json(#"""
    { "rooms": {
        "a": { "temperature": {"entity_id":"climate.x","source":"attribute"} },
        "b": { "temperature": {"source":"state"} },
        "c": { "temperature": {"entity_id":"sensor.ok","source":"state"} } } }
    """#))
    #expect(doc.nominations["a"] == nil)
    #expect(doc.nominations["b"] == nil)
    #expect(doc.nominations["c"]?.temperature?.entityId == "sensor.ok")
}

// MARK: - Display names

@Test func aDisplayNameRoundTrips() {
    let doc = DashboardDocument().settingDisplayName("Reading Lamp", for: "light.kitchen")
    #expect(doc.displayNames == ["light.kitchen": "Reading Lamp"])
}

/// The property this whole type exists to defend, extended to the new subtree: a build that knows
/// about `entities` must not strip what a newer build wrote — neither unknown top-level keys, nor
/// unknown keys *inside* an entity it is editing.
@Test func writingANameKeepsEveryKeyItDoesNotOwn() {
    let raw = JSONValue.object([
        "schema": .int(1),
        "tiles": .object(["order": .array([.string("light.kitchen")])]),
        "entities": .object([
            "light.kitchen": .object(["name": .string("Old"), "icon": .string("mdi:lamp")]),
            "light.hall": .object(["name": .string("Hall")]),
        ]),
    ])
    let doc = DashboardDocument(raw: raw).settingDisplayName("New", for: "light.kitchen")
    let root = doc.raw.asObject
    #expect(root?["tiles"] != nil)
    let kitchen = root?["entities"]?.asObject?["light.kitchen"]?.asObject
    #expect(kitchen?["name"]?.asString == "New")
    #expect(kitchen?["icon"]?.asString == "mdi:lamp")
    #expect(root?["entities"]?.asObject?["light.hall"]?.asObject?["name"]?.asString == "Hall")
}

/// Clearing an override deletes the key rather than storing an empty string, so the document does
/// not accumulate a tombstone per device the user ever renamed and changed their mind about.
@Test func clearingANameRemovesTheKeyButKeepsTheEntitysOtherKeys() {
    let raw = JSONValue.object([
        "entities": .object(["light.kitchen": .object(["name": .string("Old"),
                                                       "icon": .string("mdi:lamp")])]),
    ])
    let doc = DashboardDocument(raw: raw).settingDisplayName(nil, for: "light.kitchen")
    #expect(doc.displayNames.isEmpty)
    #expect(doc.raw.asObject?["entities"]?.asObject?["light.kitchen"]?.asObject?["icon"]?.asString == "mdi:lamp")
}

/// A blank name is the same instruction as clearing it — see `DisplayName`, which treats a
/// whitespace-only override as absent. Storing it would leave a document whose name is present but
/// means nothing.
@Test func aBlankNameClearsRatherThanStores() {
    let doc = DashboardDocument()
        .settingDisplayName("Reading Lamp", for: "light.kitchen")
        .settingDisplayName("   ", for: "light.kitchen")
    #expect(doc.displayNames.isEmpty)
}

@Test func namesAndNominationsDoNotDisturbEachOther() {
    let doc = DashboardDocument()
        .merging(["living": RoomEnvironmentOverride(
            temperature: UpliftedSensor(role: .temperature, entityId: "sensor.t", source: .state))])
        .settingDisplayName("Reading Lamp", for: "light.kitchen")
    #expect(doc.nominations["living"]?.temperature?.entityId == "sensor.t")
    #expect(doc.displayNames["light.kitchen"] == "Reading Lamp")
}

@Test func aMalformedEntitiesSubtreeIsIgnoredNotFatal() {
    let raw = JSONValue.object(["entities": .string("nonsense")])
    #expect(DashboardDocument(raw: raw).displayNames.isEmpty)
}

// MARK: - Surface membership

@Test func aMembershipRoundTripsPerSurface() {
    let doc = DashboardDocument()
        .settingMembership(.hidden, for: "light.kitchen", on: .overview)
        .settingMembership(.shown, for: "sensor.hum", on: .overview)
    #expect(doc.surfaceOverrides["light.kitchen"]?[.overview] == .hidden)
    #expect(doc.surfaceOverrides["sensor.hum"]?[.overview] == .shown)
    // Untouched surfaces stay absent, which is what "follow curation" is.
    #expect(doc.surfaceOverrides["light.kitchen"]?[.roomDetail] == nil)
}

/// The surfaces are independent, which is the whole decision this feature rests on: removing a
/// device from the dashboard must say nothing about room detail.
@Test func writingOneSurfaceLeavesTheOtherAlone() {
    let doc = DashboardDocument()
        .settingMembership(.hidden, for: "light.kitchen", on: .overview)
        .settingMembership(.hidden, for: "light.kitchen", on: .roomDetail)
        .settingMembership(nil, for: "light.kitchen", on: .overview)
    #expect(doc.surfaceOverrides["light.kitchen"]?[.overview] == nil)
    #expect(doc.surfaceOverrides["light.kitchen"]?[.roomDetail] == .hidden)
}

/// The property this type exists to defend, now across two subtrees of one entity: a name and a
/// membership are written by different sheets and must not disturb each other, and neither may strip
/// a key a newer build wrote.
@Test func membershipAndNameAndUnknownKeysCoexist() {
    let raw = JSONValue.object([
        "entities": .object(["light.kitchen": .object([
            "name": .string("Reading Lamp"),
            "icon": .string("mdi:lamp"),
            "surfaces": .object(["room_detail": .string("hidden")]),
        ])]),
    ])
    let doc = DashboardDocument(raw: raw)
        .settingMembership(.hidden, for: "light.kitchen", on: .overview)
    #expect(doc.displayNames["light.kitchen"] == "Reading Lamp")
    #expect(doc.surfaceOverrides["light.kitchen"]?[.overview] == .hidden)
    #expect(doc.surfaceOverrides["light.kitchen"]?[.roomDetail] == .hidden)
    let entity = doc.raw.asObject?["entities"]?.asObject?["light.kitchen"]?.asObject
    #expect(entity?["icon"]?.asString == "mdi:lamp")
}

/// Clearing the last membership removes `surfaces`, and clearing the last key removes the entity —
/// so a document that has been edited and un-edited ends where it started rather than carrying a
/// shell per device anyone ever opened.
@Test func clearingTheLastMembershipLeavesNoResidue() {
    let doc = DashboardDocument()
        .settingMembership(.hidden, for: "light.kitchen", on: .overview)
        .settingMembership(nil, for: "light.kitchen", on: .overview)
    #expect(doc.surfaceOverrides.isEmpty)
    #expect(doc.raw.asObject?["entities"] == nil)
}

@Test func aMalformedOrUnknownMembershipIsIgnoredNotFatal() {
    let raw = JSONValue.object([
        "entities": .object([
            "light.a": .object(["surfaces": .string("nonsense")]),
            "light.b": .object(["surfaces": .object(["overview": .string("sideways")])]),
            "light.c": .object(["surfaces": .object(["kitchen_wall": .string("hidden")])]),
        ]),
    ])
    // An unreadable value, an unknown membership and an unknown surface all drop out rather than
    // taking the document with them — a build that adds a third surface must not brick this one.
    #expect(DashboardDocument(raw: raw).surfaceOverrides.isEmpty)
}

// MARK: - The no-migration promise for a vocabulary that has left

/// Per-entity tile sizing (`entities.<id>.sizes`, `settingSize`, the `tileSizes` accessor) left the
/// schema in Task 7 — decision 5, subsection sizing replaced it. Nothing in this build parses
/// `sizes` any more, and that is exactly the risk this pins: an unrelated mutator that rebuilt an
/// entity's record from only the keys it understands, rather than merging into what is already
/// there, would silently drop a legacy `sizes` subtree the moment somebody edited that entity for
/// any other reason — the spec's no-migration promise, defended the same way
/// `mergePreservesEveryUnknownKey` defends it at the document's top level.
///
/// Two cases, because the promise fails two different ways:
/// - An edit **beside** a legacy `sizes` key must not disturb it.
/// - An edit that empties every key this build *does* understand must not conclude the record holds
///   nothing and remove it — `sizes` is still there, unread but present, and
///   `settingDisplayName(nil, for:)`'s own empty-record cleanup must not fire out from under it.
///
/// Compared as `JSONValue`, not serialized bytes — this file's own rule (see the top-level
/// forward-compatibility test above): key ordering and number normalisation are not bugs worth a
/// flaky test.
@Test func aLegacyEntitySizeSurvivesAnUnrelatedMutation() {
    let raw = JSONValue.object([
        "schema": .int(DashboardDocument.schema),
        "entities": .object(["sensor.hall": .object([
            "name": .string("Hallway"),
            "sizes": .object(["overview": .string("2x1")])])])])
    let sizes = JSONValue.object(["overview": .string("2x1")])

    // Beside: renaming the entity leaves its legacy `sizes` subtree untouched.
    let renamed = DashboardDocument(raw: raw).settingDisplayName("Landing", for: "sensor.hall")
    #expect(renamed.raw.asObject?["entities"]?.asObject?["sensor.hall"]?.asObject?["sizes"] == sizes)

    // Empty: clearing the only key this build understands must not delete the record out from
    // under a legacy key it cannot read.
    let cleared = DashboardDocument(raw: raw).settingDisplayName(nil, for: "sensor.hall")
    #expect(cleared.raw.asObject?["entities"]?.asObject?["sensor.hall"]?.asObject?["sizes"] == sizes)
}

// MARK: - How a two-state tile shows its state

@Test func aStateStyleIsStoredPerEntityRatherThanPerSurface() {
    let doc = DashboardDocument().settingStateStyle(.label, for: "binary_sensor.front")
    #expect(doc.tileStateStyles["binary_sensor.front"] == .label)
}

@Test func aStateStyleSurvivesTheOtherDecisionsAboutADevice() {
    let doc = DashboardDocument()
        .settingDisplayName("Front Door", for: "binary_sensor.front")
        .settingStateStyle(.label, for: "binary_sensor.front")
    #expect(doc.displayNames["binary_sensor.front"] == "Front Door")
    #expect(doc.tileStateStyles["binary_sensor.front"] == .label)
}

@Test func clearingTheStateStyleRemovesTheRecord() {
    let doc = DashboardDocument()
        .settingStateStyle(.label, for: "binary_sensor.front")
        .settingStateStyle(nil, for: "binary_sensor.front")
    #expect(doc.tileStateStyles["binary_sensor.front"] == nil)
    #expect(doc.raw.asObject?["entities"] == nil)
}

/// A style a newer build understands and this one does not is dropped rather than guessed at.
@Test func anUnreadableStateStyleIsIgnored() {
    let doc = DashboardDocument(raw: .object([
        "schema": .int(DashboardDocument.schema),
        "entities": .object(["binary_sensor.front": .object([
            "state_style": .string("interpretive-dance")])])]))
    #expect(doc.tileStateStyles["binary_sensor.front"] == nil)
}

// MARK: - Per-surface tile order (design decision 9)

/// **Arranging one surface must leave the other's list exactly as it was.**
///
/// This is the merge discipline every mutator here follows, and here it is load-bearing rather than
/// tidy: the two surfaces are arranged independently, so a write that replaced the whole `order`
/// object would make arranging the dashboard silently discard the arrangement of the room you had
/// opened — the very defect per-surface order exists to end, reintroduced one level down.
///
/// Both surfaces are written and *both* are read back. Reading only the second would pass against a
/// mutator that replaces the object wholesale, which is precisely the implementation this guards.
@Test func arrangingOneSurfaceLeavesTheOthersListAlone() {
    let doc = DashboardDocument()
        .settingOrder(["light.a", "light.b"], forRoom: "living", on: .overview)
        .settingOrder(["sensor.x", "light.a"], forRoom: "living", on: .roomDetail)

    #expect(doc.order(forRoom: "living", on: .overview) == ["light.a", "light.b"])
    #expect(doc.order(forRoom: "living", on: .roomDetail) == ["sensor.x", "light.a"])

    // And re-writing one still does not disturb the other.
    let again = doc.settingOrder(["light.b", "light.a"], forRoom: "living", on: .overview)
    #expect(again.order(forRoom: "living", on: .overview) == ["light.b", "light.a"])
    #expect(again.order(forRoom: "living", on: .roomDetail) == ["sensor.x", "light.a"])
}

/// The stored shape, asserted directly: an object keyed by `HavenSurface`'s raw values, `room_detail`
/// spelled as it is on the wire. Other builds read this JSON, so the shape is part of the contract
/// and not an implementation detail the accessors happen to agree on.
@Test func anOrderIsStoredAsAnObjectKeyedBySurface() {
    let doc = DashboardDocument().settingOrder(["light.a"], forRoom: "living", on: .roomDetail)
    let order = doc.raw.asObject?["rooms"]?.asObject?["living"]?.asObject?["order"]?.asObject
    #expect(order?["room_detail"]?.asArray?.compactMap(\.asString) == ["light.a"])
    #expect(order?["overview"] == nil)
}

/// Clearing the last surface removes `order` entirely rather than leaving an empty object behind —
/// which is what lets the room-record cleanup fire and a reset leave the document as it started.
@Test func clearingEverySurfaceLeavesNoOrderHusk() {
    let doc = DashboardDocument()
        .settingOrder(["light.a"], forRoom: "living", on: .overview)
        .settingOrder(["light.a"], forRoom: "living", on: .roomDetail)
        .settingOrder([], forRoom: "living", on: .overview)
    #expect(doc.raw.asObject?["rooms"]?.asObject?["living"]?.asObject?["order"] != nil)

    let cleared = doc.settingOrder([], forRoom: "living", on: .roomDetail)
    // No `"order": {}`, and with nothing else stored for this room, no room record either.
    #expect(cleared.raw.asObject?["rooms"] == nil)
    #expect(cleared.orders(forRoom: "living").isEmpty)
}

/// **A development document carrying the old single-array shape reads as unset**, on both surfaces —
/// the spec's no-migration promise (decision 9). Nothing has shipped, so a document that falls back
/// to the default order once is cheaper than a migration nobody will need again.
@Test func aLegacyArrayOrderReadsAsUnset() {
    let doc = DashboardDocument(raw: .object([
        "schema": .int(DashboardDocument.schema),
        "rooms": .object(["living": .object([
            "order": .array([.string("light.a"), .string("light.b")])])])]))
    #expect(doc.orders(forRoom: "living").isEmpty)
    #expect(doc.order(forRoom: "living", on: .overview).isEmpty)
    #expect(doc.order(forRoom: "living", on: .roomDetail).isEmpty)
}

/// A surface key this build does not recognise is dropped rather than defaulted, exactly as
/// `surfaceOverrides` drops what it cannot read — a newer build's third surface must leave this one
/// working, not make it claim an arrangement it cannot render.
@Test func anUnknownSurfaceKeyInAnOrderIsDropped() {
    let doc = DashboardDocument(raw: .object([
        "schema": .int(DashboardDocument.schema),
        "rooms": .object(["living": .object([
            "order": .object([
                "overview": .array([.string("light.a")]),
                "wall_panel": .array([.string("light.b")])])])])]))
    #expect(doc.orders(forRoom: "living") == [.overview: ["light.a"]])
}

/// The property this type exists to defend, on the new subtree: writing one surface's order keeps
/// every key it does not own, inside the room record and outside it.
@Test func writingAnOrderKeepsEveryKeyItDoesNotOwn() {
    let raw = JSONValue.object([
        "schema": .int(1),
        "display": .object(["mode": .string("wrap")]),
        "rooms": .object(["living": .object([
            "label": .string("Lounge"),
            "order": .object(["room_detail": .array([.string("sensor.x")])])])])])
    let doc = DashboardDocument(raw: raw).settingOrder(["light.a"], forRoom: "living", on: .overview)
    let root = doc.raw.asObject
    #expect(root?["display"] != nil)
    let living = root?["rooms"]?.asObject?["living"]?.asObject
    #expect(living?["label"]?.asString == "Lounge")
    #expect(doc.order(forRoom: "living", on: .roomDetail) == ["sensor.x"])
    #expect(doc.order(forRoom: "living", on: .overview) == ["light.a"])
}
