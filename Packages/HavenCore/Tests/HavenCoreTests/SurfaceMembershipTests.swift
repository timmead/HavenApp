import Foundation
import Testing
@testable import HavenCore

/// The whole matrix: four tiers × two surfaces × three override states. Written out rather than
/// looped because the interesting content is *which* cells differ, and a loop over the rule would
/// only restate the rule.
@Test func withoutAnOverrideEachSurfaceRendersItsOwnTiers() {
    // The overview is controls only.
    #expect(SurfaceMembership.shows(tier: .primary, on: .overview, override: nil))
    #expect(!SurfaceMembership.shows(tier: .secondary, on: .overview, override: nil))
    #expect(!SurfaceMembership.shows(tier: .companion, on: .overview, override: nil))
    #expect(!SurfaceMembership.shows(tier: .hidden, on: .overview, override: nil))

    // Room detail adds the sensors curation demoted off the grid.
    #expect(SurfaceMembership.shows(tier: .primary, on: .roomDetail, override: nil))
    #expect(SurfaceMembership.shows(tier: .secondary, on: .roomDetail, override: nil))
    #expect(!SurfaceMembership.shows(tier: .companion, on: .roomDetail, override: nil))
    #expect(!SurfaceMembership.shows(tier: .hidden, on: .roomDetail, override: nil))
}

@Test func hiddenTakesADeviceOffThatSurfaceWhateverItsTier() {
    #expect(!SurfaceMembership.shows(tier: .primary, on: .overview, override: .hidden))
    #expect(!SurfaceMembership.shows(tier: .primary, on: .roomDetail, override: .hidden))
    #expect(!SurfaceMembership.shows(tier: .secondary, on: .roomDetail, override: .hidden))
}

/// `shown` is what makes the + an addition rather than an undo: it puts a device on a surface
/// curation left off it, including `.companion` telemetry a user genuinely wants a tile for.
@Test func shownPutsADeviceOnASurfaceCurationLeftItOff() {
    #expect(SurfaceMembership.shows(tier: .secondary, on: .overview, override: .shown))
    #expect(SurfaceMembership.shows(tier: .companion, on: .overview, override: .shown))
    #expect(SurfaceMembership.shows(tier: .companion, on: .roomDetail, override: .shown))
}

/// **The one exception, and the reason the rule is a function rather than a set lookup.** A
/// `.hidden` tier is Home Assistant's own doing (`hidden_by`) or its `entity_category`, and HA
/// outranks anything Haven decides. The picker never offers these, so a `shown` override cannot
/// arise through the UI — this refuses it anyway, so a hand-edited document cannot make Haven
/// contradict Home Assistant.
@Test func shownCannotResurrectWhatHomeAssistantHid() {
    #expect(!SurfaceMembership.shows(tier: .hidden, on: .overview, override: .shown))
    #expect(!SurfaceMembership.shows(tier: .hidden, on: .roomDetail, override: .shown))
}

@Test func theSurfacesAndOverridesRoundTripAsStrings() {
    #expect(HavenSurface(rawValue: "overview") == .overview)
    #expect(HavenSurface(rawValue: "room_detail") == .roomDetail)
    #expect(HavenSurface.allCases.count == 2)
    #expect(SurfaceMembership(rawValue: "hidden") == .hidden)
    #expect(SurfaceMembership(rawValue: "shown") == .shown)
}
