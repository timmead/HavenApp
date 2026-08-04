import Foundation
import Testing
@testable import HavenCore

@Test func theOverrideOutranksHomeAssistantsOwnName() {
    #expect(DisplayName.resolve(override: "Reading Lamp",
                                friendlyName: "Kitchen Light",
                                entityId: "light.kitchen") == "Reading Lamp")
}

@Test func withoutAnOverrideHomeAssistantsNameWins() {
    #expect(DisplayName.resolve(override: nil,
                                friendlyName: "Kitchen Light",
                                entityId: "light.kitchen") == "Kitchen Light")
}

@Test func withNeitherTheNameIsDerivedFromTheEntityId() {
    #expect(DisplayName.resolve(override: nil, friendlyName: nil,
                                entityId: "light.kitchen_bench") == "Kitchen Bench")
}

/// Clearing the field in the rename sheet must reset to Home Assistant's name rather than render a
/// blank tile — so an override that is empty, or only whitespace, is treated as no override at all.
/// The same rule applies to `friendly_name`, which Home Assistant can carry as an empty string.
@Test func blankNamesAreTreatedAsAbsentAtEveryRung() {
    #expect(DisplayName.resolve(override: "", friendlyName: "Kitchen Light",
                                entityId: "light.kitchen") == "Kitchen Light")
    #expect(DisplayName.resolve(override: "   ", friendlyName: "Kitchen Light",
                                entityId: "light.kitchen") == "Kitchen Light")
    #expect(DisplayName.resolve(override: nil, friendlyName: "  ",
                                entityId: "light.kitchen") == "Kitchen")
}

@Test func namesAreTrimmedBeforeUse() {
    #expect(DisplayName.resolve(override: "  Reading Lamp  ", friendlyName: nil,
                                entityId: "light.kitchen") == "Reading Lamp")
}

@Test func snakeCaseTokensRenderAsWords() {
    #expect(DisplayName.words("heat_cool") == "Heat Cool")
    #expect(DisplayName.words("fan_only") == "Fan Only")
}

// MARK: - Writing a draft back

/// **Blank is not a name, it is the absence of one.** The configuration sheet's field starts empty
/// for a device nobody has renamed, so "" has to mean "no override" rather than an override to
/// nothing — which would shadow Home Assistant's name with a blank tile caption.
@Test func anEmptyDraftIsNoOverrideAtAll() {
    #expect(DisplayName.override(from: "") == nil)
    #expect(DisplayName.override(from: "   ") == nil)
    #expect(DisplayName.override(from: "\n\t ") == nil)
}

@Test func aDraftIsStoredTrimmed() {
    #expect(DisplayName.override(from: "  Reading Lamp  ") == "Reading Lamp")
    #expect(DisplayName.override(from: "Reading Lamp") == "Reading Lamp")
}

/// Interior spacing is the user's business — only the ends are noise.
@Test func interiorSpacingSurvivesTheTrim() {
    #expect(DisplayName.override(from: " Hall  Light ") == "Hall  Light")
}

/// The rule that reads and the rule that writes are the same rule, and this is what says so: a draft
/// stored through `override` and read back through `resolve` must round-trip.
@Test func whatIsWrittenIsWhatIsRead() {
    let stored = DisplayName.override(from: "  Reading Lamp  ")
    #expect(DisplayName.resolve(override: stored, friendlyName: "Kitchen Light",
                                entityId: "light.kitchen") == "Reading Lamp")
    let cleared = DisplayName.override(from: "   ")
    #expect(DisplayName.resolve(override: cleared, friendlyName: "Kitchen Light",
                                entityId: "light.kitchen") == "Kitchen Light")
}
