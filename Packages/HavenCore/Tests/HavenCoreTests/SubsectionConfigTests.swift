import Testing
import Foundation
@testable import HavenCore

private func json(_ text: String) -> JSONValue {
    try! HACoding.decoder.decode(JSONValue.self, from: Data(text.utf8))
}

// MARK: - Household display mode

@Test func aDisplayModeRoundTrips() {
    let doc = DashboardDocument().settingDisplayMode(.wrap)
    #expect(doc.displayMode == .wrap)
}

@Test func absentDisplayModeReadsAsNil() {
    #expect(DashboardDocument().displayMode == nil)
}

/// Clearing removes the key rather than writing a null, so an unconfigured household leaves no
/// residue behind for the built-in default to fall through — the same discipline every other
/// mutator in this document holds.
@Test func clearingTheDisplayModeRemovesTheKeyRatherThanWritingNull() {
    let doc = DashboardDocument()
        .settingDisplayMode(.wrap)
        .settingDisplayMode(nil)
    #expect(doc.displayMode == nil)
    #expect(doc.raw.asObject?["display"] == nil)
}

// MARK: - Per-subsection size (decision 10: per-surface) and mode (still per-kind)

@Test func aSubsectionSpanRoundTrips() {
    let doc = DashboardDocument()
        .settingSubsectionSpan(TileSpan(columns: 4, rows: 2), kind: .climate, on: .overview)
    #expect(doc.subsectionSpan(.climate, on: .overview) == TileSpan(columns: 4, rows: 2))
}

@Test func aSubsectionModeRoundTrips() {
    let doc = DashboardDocument().settingSubsectionMode(.wrap, kind: .cameras)
    #expect(doc.subsectionMode(.cameras) == .wrap)
}

/// **Decision 10, mirroring decision 9's `arrangingOneSurfaceLeavesTheOthersListAlone`.** Writing
/// one surface's span must leave the other surface's span, and the kind's `mode`, exactly as they
/// were. Load-bearing rather than tidy: the two surfaces are sized independently, so a write that
/// replaced the whole `size` object would make choosing a camera's size on the floor silently
/// discard whatever room detail had chosen — the very defect per-surface size exists to end.
@Test func writingOneSurfacesSpanLeavesTheOtherSurfaceAndTheKindsModeAlone() {
    let doc = DashboardDocument()
        .settingSubsectionSpan(TileSpan(columns: 4, rows: 2), kind: .cameras, on: .roomDetail)
        .settingSubsectionMode(.wrap, kind: .cameras)
        .settingSubsectionSpan(TileSpan(columns: 2, rows: 2), kind: .cameras, on: .overview)
    #expect(doc.subsectionSpan(.cameras, on: .overview) == TileSpan(columns: 2, rows: 2))
    #expect(doc.subsectionSpan(.cameras, on: .roomDetail) == TileSpan(columns: 4, rows: 2))
    #expect(doc.subsectionMode(.cameras) == .wrap)
}

/// The write side of the same discipline: `size` is stored as an object keyed by surface, not a
/// flat string — mirrors `anOrderIsStoredAsAnObjectKeyedBySurface`.
@Test func aSubsectionSpanIsStoredAsAnObjectKeyedBySurface() {
    let doc = DashboardDocument()
        .settingSubsectionSpan(TileSpan(columns: 2, rows: 2), kind: .cameras, on: .roomDetail)
    let size = doc.raw.asObject?["subsections"]?.asObject?["cameras"]?.asObject?["size"]?.asObject
    #expect(size?["room_detail"]?.asString == "2x2")
    #expect(size?["overview"] == nil)
}

/// Clearing a subsection's size on one surface removes only that surface's key, so a mode chosen
/// for the same kind — and a span chosen for the *other* surface — both survive. Extends
/// `clearingASubsectionSpanRemovesTheKeyRatherThanWritingNull` across the new surface axis.
@Test func clearingASubsectionSpanRemovesOnlyThatSurfacesKey() {
    let doc = DashboardDocument()
        .settingSubsectionSpan(TileSpan(columns: 4, rows: 2), kind: .climate, on: .overview)
        .settingSubsectionSpan(TileSpan(columns: 4, rows: 2), kind: .climate, on: .roomDetail)
        .settingSubsectionMode(.wrap, kind: .climate)
        .settingSubsectionSpan(nil, kind: .climate, on: .overview)
    #expect(doc.subsectionSpan(.climate, on: .overview) == nil)
    #expect(doc.subsectionSpan(.climate, on: .roomDetail) == TileSpan(columns: 4, rows: 2))
    #expect(doc.subsectionMode(.climate) == .wrap)
    // The accessor alone can't tell a removed key from a stored null — both read back as `nil`
    // through `.asString` — so check the raw shape too.
    let size = doc.raw.asObject?["subsections"]?.asObject?["climate"]?.asObject?["size"]?.asObject
    #expect(size?["overview"] == nil)
    #expect(size?["room_detail"]?.asString == "4x2")
}

/// Mirrors the span test above: clearing a subsection's mode removes only that key, so a size
/// chosen for the same kind survives, and the raw shape shows the key gone rather than holding a
/// stored null.
@Test func clearingASubsectionModeRemovesTheKeyRatherThanWritingNull() {
    let doc = DashboardDocument()
        .settingSubsectionSpan(TileSpan(columns: 4, rows: 2), kind: .climate, on: .overview)
        .settingSubsectionMode(.wrap, kind: .climate)
        .settingSubsectionMode(nil, kind: .climate)
    #expect(doc.subsectionMode(.climate) == nil)
    #expect(doc.subsectionSpan(.climate, on: .overview) == TileSpan(columns: 4, rows: 2))
    let climate = doc.raw.asObject?["subsections"]?.asObject?["climate"]?.asObject
    #expect(climate?["mode"] == nil)
}

/// Clearing the last setting for a kind leaves no shell behind, or the document fills up with empty
/// records of decisions nobody is making any more — see `clearingTheLastSizeRemovesTheRecord`.
@Test func clearingTheLastSubsectionSettingRemovesTheRecord() {
    let doc = DashboardDocument()
        .settingSubsectionSpan(TileSpan(columns: 4, rows: 2), kind: .climate, on: .overview)
        .settingSubsectionSpan(nil, kind: .climate, on: .overview)
    #expect(doc.subsectionSpan(.climate, on: .overview) == nil)
    #expect(doc.raw.asObject?["subsections"] == nil)
}

/// Clearing the *last remaining* surface's span leaves no `"size": {}` husk behind — mirrors
/// `clearingEverySurfaceLeavesNoOrderHusk`, and is distinct from the single-surface case above:
/// this one starts with *both* surfaces set.
@Test func clearingEverySurfacesSpanLeavesNoSizeHusk() {
    let doc = DashboardDocument()
        .settingSubsectionSpan(TileSpan(columns: 4, rows: 2), kind: .cameras, on: .overview)
        .settingSubsectionSpan(TileSpan(columns: 4, rows: 2), kind: .cameras, on: .roomDetail)
        .settingSubsectionSpan(nil, kind: .cameras, on: .overview)
    #expect(doc.raw.asObject?["subsections"]?.asObject?["cameras"]?.asObject?["size"] != nil)

    let cleared = doc.settingSubsectionSpan(nil, kind: .cameras, on: .roomDetail)
    // No `"size": {}`, and with nothing else stored for this kind, no kind record either.
    #expect(cleared.raw.asObject?["subsections"] == nil)
    #expect(cleared.subsectionSpan(.cameras, on: .overview) == nil)
    #expect(cleared.subsectionSpan(.cameras, on: .roomDetail) == nil)
}

/// A size written by a build that knows a shape this one does not is dropped, not guessed at — the
/// same discipline `surfaceOverrides` already holds for values it cannot read.
@Test func aGarbageSizeStringReadsAsNil() {
    let doc = DashboardDocument(raw: .object([
        "schema": .int(DashboardDocument.schema),
        "subsections": .object(["climate": .object(
            ["size": .object(["overview": .string("enormous")])])])]))
    #expect(doc.subsectionSpan(.climate, on: .overview) == nil)
}

/// **Decision 10's own migration rule, mirroring `aLegacyArrayOrderReadsAsUnset`.** A document
/// written before size became per-surface still has a plain string at `size` — a value that was
/// perfectly valid under the old schema — and it must read as unset on every surface rather than
/// crash, half-parse, or claim the household chose something for a surface the old schema never
/// distinguished.
@Test func aLegacySingleStringSizeReadsAsUnset() {
    let doc = DashboardDocument(raw: .object([
        "schema": .int(DashboardDocument.schema),
        "subsections": .object(["cameras": .object(["size": .string("4x2")])])]))
    #expect(doc.subsectionSpan(.cameras, on: .overview) == nil)
    #expect(doc.subsectionSpan(.cameras, on: .roomDetail) == nil)
}

/// A surface key this build does not recognise is dropped rather than defaulted, exactly as
/// `orders(forRoom:)` drops one — mirrors `anUnknownSurfaceKeyInAnOrderIsDropped`.
@Test func anUnknownSurfaceKeyInASpanIsDropped() {
    let doc = DashboardDocument(raw: .object([
        "schema": .int(DashboardDocument.schema),
        "subsections": .object(["cameras": .object(["size": .object([
            "overview": .string("2x2"),
            "wall_panel": .string("4x2")])])])]))
    #expect(doc.subsectionSpan(.cameras, on: .overview) == TileSpan(columns: 2, rows: 2))
    #expect(doc.subsectionSpan(.cameras, on: .roomDetail) == nil)
}

/// Likewise for a mode this build does not recognise.
@Test func aGarbageModeStringReadsAsNil() {
    let doc = DashboardDocument(raw: .object([
        "subsections": .object(["climate": .object(["mode": .string("sideways")])])]))
    #expect(doc.subsectionMode(.climate) == nil)
}

/// Writing one kind's settings must not disturb a sibling kind's — the write path's own
/// merge-discipline test: a mutator that dropped unmentioned keys inside `subsections` would
/// silently erase every other kind's configuration on its next write.
@Test func writingOneKindsSettingsLeavesASiblingKindAlone() {
    let doc = DashboardDocument()
        .settingSubsectionSpan(TileSpan(columns: 2, rows: 2), kind: .cameras, on: .overview)
        .settingSubsectionMode(.wrap, kind: .cameras)
        .settingSubsectionSpan(TileSpan(columns: 4, rows: 2), kind: .climate, on: .overview)
    #expect(doc.subsectionSpan(.climate, on: .overview) == TileSpan(columns: 4, rows: 2))
    #expect(doc.subsectionSpan(.cameras, on: .overview) == TileSpan(columns: 2, rows: 2))
    #expect(doc.subsectionMode(.cameras) == .wrap)
}

/// Mirrors `writingOneKindsSettingsLeavesASiblingKindAlone` for a mode write rather than a span
/// write — the two mutators share the same two-level merge, and each needs its own sibling-safety
/// case rather than one standing in for the other.
@Test func writingOneKindsModeLeavesASiblingKindAlone() {
    let doc = DashboardDocument()
        .settingSubsectionSpan(TileSpan(columns: 2, rows: 2), kind: .cameras, on: .overview)
        .settingSubsectionMode(.wrap, kind: .cameras)
        .settingSubsectionMode(.wrap, kind: .climate)
    #expect(doc.subsectionMode(.climate) == .wrap)
    #expect(doc.subsectionSpan(.cameras, on: .overview) == TileSpan(columns: 2, rows: 2))
    #expect(doc.subsectionMode(.cameras) == .wrap)
}

/// The property this whole document type exists to defend, extended to the new subtrees: a
/// subsection write must not strip a key this build has never heard of, either at the top level or
/// inside `subsections`/`display` — and, on the size axis, not strip a *sibling surface's* key
/// either, which is the new half decision 10 adds.
@Test func subsectionWritesKeepEveryUnknownKey() {
    let original = json(#"""
    { "schema": 1,
      "somethingAFutureBuildAdded": { "nested": true },
      "display": { "order": ["climate", "lights"] },
      "subsections": {
        "climate": { "size": { "room_detail": "4x2" }, "somethingNew": true },
        "lights": { "size": { "overview": "1x1" } },
        "fireplaces": { "size": { "overview": "2x2" } } } }
    """#)
    let doc = DashboardDocument(raw: original)
        .settingSubsectionSpan(TileSpan(columns: 2, rows: 1), kind: .lights, on: .overview)
        .settingSubsectionMode(.wrap, kind: .climate)
        .settingDisplayMode(.wrap)
    let root = doc.raw.asObject

    #expect(root?["somethingAFutureBuildAdded"] == original.asObject?["somethingAFutureBuildAdded"])
    #expect(root?["display"]?.asObject?["order"] == json(#"["climate","lights"]"#))

    let climate = root?["subsections"]?.asObject?["climate"]?.asObject
    // The mode write did not touch climate's size, on either surface.
    #expect(climate?["size"]?.asObject?["room_detail"]?.asString == "4x2")
    #expect(climate?["somethingNew"]?.asBool == true)
    #expect(climate?["mode"]?.asString == "wrap")

    // The lights write itself lands on `.overview`...
    #expect(root?["subsections"]?.asObject?["lights"]?.asObject?["size"]?.asObject?["overview"]?.asString == "2x1")
    // ...and a kind key this build doesn't otherwise touch survives a span write on a sibling.
    #expect(root?["subsections"]?.asObject?["fireplaces"] ==
             original.asObject?["subsections"]?.asObject?["fireplaces"])
}

// MARK: - Schema stamp

@Test func aSubsectionWriteStampsSchema() {
    let doc = DashboardDocument(raw: .object([:]))
        .settingSubsectionSpan(TileSpan(columns: 1, rows: 1), kind: .lights, on: .overview)
    #expect(doc.raw.asObject?["schema"]?.asInt == DashboardDocument.schema)
}

@Test func aDisplayModeWriteStampsSchema() {
    let doc = DashboardDocument(raw: .object([:])).settingDisplayMode(.wrap)
    #expect(doc.raw.asObject?["schema"]?.asInt == DashboardDocument.schema)
}

@Test func aSubsectionModeWriteStampsSchema() {
    let doc = DashboardDocument(raw: .object([:]))
        .settingSubsectionMode(.wrap, kind: .lights)
    #expect(doc.raw.asObject?["schema"]?.asInt == DashboardDocument.schema)
}
