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
