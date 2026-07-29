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
