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

// MARK: - Per-subsection size and mode

@Test func aSubsectionSpanRoundTrips() {
    let doc = DashboardDocument().settingSubsectionSpan(TileSpan(columns: 4, rows: 2), kind: .climate)
    #expect(doc.subsectionSpan(.climate) == TileSpan(columns: 4, rows: 2))
}

@Test func aSubsectionModeRoundTrips() {
    let doc = DashboardDocument().settingSubsectionMode(.wrap, kind: .cameras)
    #expect(doc.subsectionMode(.cameras) == .wrap)
}

/// Clearing a subsection's size removes only that key, so a mode chosen for the same kind survives
/// clearing its size and vice versa — the discipline `settingSize`/`settingStateStyle` already hold
/// for per-entity settings.
@Test func clearingASubsectionSpanRemovesTheKeyRatherThanWritingNull() {
    let doc = DashboardDocument()
        .settingSubsectionSpan(TileSpan(columns: 4, rows: 2), kind: .climate)
        .settingSubsectionMode(.wrap, kind: .climate)
        .settingSubsectionSpan(nil, kind: .climate)
    #expect(doc.subsectionSpan(.climate) == nil)
    #expect(doc.subsectionMode(.climate) == .wrap)
    // The accessor alone can't tell a removed key from a stored null — both read back as `nil`
    // through `.asString` — so check the raw shape too.
    let climate = doc.raw.asObject?["subsections"]?.asObject?["climate"]?.asObject
    #expect(climate?["size"] == nil)
}

/// Clearing the last setting for a kind leaves no shell behind, or the document fills up with empty
/// records of decisions nobody is making any more — see `clearingTheLastSizeRemovesTheRecord`.
@Test func clearingTheLastSubsectionSettingRemovesTheRecord() {
    let doc = DashboardDocument()
        .settingSubsectionSpan(TileSpan(columns: 4, rows: 2), kind: .climate)
        .settingSubsectionSpan(nil, kind: .climate)
    #expect(doc.subsectionSpan(.climate) == nil)
    #expect(doc.raw.asObject?["subsections"] == nil)
}

/// A size written by a build that knows a shape this one does not is dropped, not guessed at — the
/// same discipline `tileSizes` already holds for per-entity sizes.
@Test func aGarbageSizeStringReadsAsNil() {
    let doc = DashboardDocument(raw: .object([
        "schema": .int(DashboardDocument.schema),
        "subsections": .object(["climate": .object(["size": .string("enormous")])])]))
    #expect(doc.subsectionSpan(.climate) == nil)
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
        .settingSubsectionSpan(TileSpan(columns: 2, rows: 2), kind: .cameras)
        .settingSubsectionMode(.wrap, kind: .cameras)
        .settingSubsectionSpan(TileSpan(columns: 4, rows: 2), kind: .climate)
    #expect(doc.subsectionSpan(.climate) == TileSpan(columns: 4, rows: 2))
    #expect(doc.subsectionSpan(.cameras) == TileSpan(columns: 2, rows: 2))
    #expect(doc.subsectionMode(.cameras) == .wrap)
}

/// The property this whole document type exists to defend, extended to the new subtrees: a
/// subsection write must not strip a key this build has never heard of, either at the top level or
/// inside `subsections`/`display`.
@Test func subsectionWritesKeepEveryUnknownKey() {
    let original = json(#"""
    { "schema": 1,
      "somethingAFutureBuildAdded": { "nested": true },
      "display": { "order": ["climate", "lights"] },
      "subsections": {
        "climate": { "size": "4x2", "somethingNew": true },
        "lights": { "size": "1x1" },
        "fireplaces": { "size": "2x2" } } }
    """#)
    let doc = DashboardDocument(raw: original)
        .settingSubsectionSpan(TileSpan(columns: 2, rows: 1), kind: .lights)
        .settingSubsectionMode(.wrap, kind: .climate)
        .settingDisplayMode(.wrap)
    let root = doc.raw.asObject

    #expect(root?["somethingAFutureBuildAdded"] == original.asObject?["somethingAFutureBuildAdded"])
    #expect(root?["display"]?.asObject?["order"] == json(#"["climate","lights"]"#))

    let climate = root?["subsections"]?.asObject?["climate"]?.asObject
    #expect(climate?["size"]?.asString == "4x2")
    #expect(climate?["somethingNew"]?.asBool == true)
    #expect(climate?["mode"]?.asString == "wrap")

    // The lights write itself lands...
    #expect(root?["subsections"]?.asObject?["lights"]?.asObject?["size"]?.asString == "2x1")
    // ...and a kind key this build doesn't otherwise touch survives a span write on a sibling.
    #expect(root?["subsections"]?.asObject?["fireplaces"] ==
             original.asObject?["subsections"]?.asObject?["fireplaces"])
}

// MARK: - Schema stamp

@Test func aSubsectionWriteStampsSchema() {
    let doc = DashboardDocument(raw: .object([:]))
        .settingSubsectionSpan(TileSpan(columns: 1, rows: 1), kind: .lights)
    #expect(doc.raw.asObject?["schema"]?.asInt == DashboardDocument.schema)
}

@Test func aDisplayModeWriteStampsSchema() {
    let doc = DashboardDocument(raw: .object([:])).settingDisplayMode(.wrap)
    #expect(doc.raw.asObject?["schema"]?.asInt == DashboardDocument.schema)
}
