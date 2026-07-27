import Testing
@testable import HavenCore

private func floor(_ id: String) -> ResolvedFloor {
    ResolvedFloor(id: id, name: id.capitalized, level: 0, areas: [])
}

@Test func selectionSurvivesAReloadThatKeepsTheFloor() {
    #expect(FloorPaging.selection(current: "up", floors: [floor("home"), floor("up")]) == "up")
}

@Test func selectionFallsBackWhenItsFloorDisappears() {
    // The floor the user was standing on was merged away; anything but a live id leaves the pager
    // scrolled to nowhere.
    #expect(FloorPaging.selection(current: "attic", floors: [floor("home"), floor("up")]) == "home")
}

@Test func selectionSeedsFromNilBeforeTheFirstScroll() {
    #expect(FloorPaging.selection(current: nil, floors: [floor("home"), floor("up")]) == "home")
}

@Test func selectionIsNilWithNoFloors() {
    #expect(FloorPaging.selection(current: "home", floors: []) == nil)
}
