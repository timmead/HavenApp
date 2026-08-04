import Foundation
import Testing
@testable import HavenCore

private func spans(_ pairs: [(Int, Int)]) -> [TileSpan] {
    pairs.map { TileSpan(columns: $0.0, rows: $0.1) }
}
private func cells(_ placements: [GridPlacement]) -> [(Int, Int)] {
    placements.map { ($0.column, $0.row) }
}
private func expectCells(_ placements: [GridPlacement], _ expected: [(Int, Int)],
                         sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(cells(placements).map { "\($0.0),\($0.1)" } == expected.map { "\($0.0),\($0.1)" },
            sourceLocation: sourceLocation)
}

@Test func onesFillARowThenWrap() {
    let placed = GridPacking.place(spans([(1, 1), (1, 1), (1, 1), (1, 1), (1, 1)]), columns: 4)
    expectCells(placed, [(0, 0), (1, 0), (2, 0), (3, 0), (0, 1)])
}

/// **The gap that stays a gap.** Three 1×1s leave one column, a 2-wide tile cannot fit it, and the
/// packer starts a new row rather than reaching forward for something that would — column 3 of row 0
/// is simply empty.
///
/// This is the whole reason the packer is sequential: sub-project 5b makes this sequence draggable,
/// and a packer that backfilled would let a tile dropped in fourth place appear fourth-from-the-gap
/// instead. Wasted space is cheaper than an order that disagrees with itself.
@Test func aWideTileThatDoesNotFitStartsANewRowAndLeavesTheGap() {
    let placed = GridPacking.place(spans([(1, 1), (1, 1), (1, 1), (2, 1), (1, 1)]), columns: 4)
    expectCells(placed, [(0, 0), (1, 0), (2, 0), (0, 1), (2, 1)])
}

/// A 2×2 owns two rows of its two columns, so the tile after it goes *beside* it, and the one after
/// that wraps to the row below the tall tile rather than into the space it occupies.
@Test func aTallTileKeepsItsColumnsForBothRows() {
    let placed = GridPacking.place(spans([(2, 2), (1, 1), (1, 1), (1, 1)]), columns: 4)
    expectCells(placed, [(0, 0), (2, 0), (3, 0), (2, 1)])
}

@Test func aFullWidthTileAlwaysStartsARow() {
    let placed = GridPacking.place(spans([(1, 1), (4, 1), (1, 1)]), columns: 4)
    expectCells(placed, [(0, 0), (0, 1), (0, 2)])
}

/// A renderer asking for more columns than the grid has is a mistake in that renderer, and the
/// useful answer is the widest thing that fits — not a crash, and not a tile that silently vanishes.
@Test func aSpanWiderThanTheGridIsClampedNotDropped() {
    let placed = GridPacking.place(spans([(6, 1), (1, 1)]), columns: 4)
    #expect(placed.count == 2)
    #expect(placed[0].span.columns == 4)
    expectCells(placed, [(0, 0), (0, 1)])
}

@Test func spansAreAtLeastOneCell() {
    #expect(TileSpan(columns: 0, rows: 0) == TileSpan(columns: 1, rows: 1))
    #expect(TileSpan(columns: -3, rows: -1) == TileSpan(columns: 1, rows: 1))
}

/// The row count has to include the rows a *tall* tile occupies, not just the row it starts in —
/// otherwise a room ending in a camera is drawn an entire row short of its own content.
@Test func rowCountIncludesTheRowsATallTileOccupies() {
    let placed = GridPacking.place(spans([(1, 1), (2, 2)]), columns: 4)
    #expect(GridPacking.rowCount(placed) == 2)
    #expect(GridPacking.rowCount([]) == 0)
}

/// Every domain, so the table cannot quietly lose a case. The sizes are exactly what each tile
/// renders at today — this sub-project changes where tiles go, never how big they are.
@Test func everyDomainHasTheSpanItsTileAlreadyRendersAt() {
    #expect(TileSpan.default(for: .light, on: .overview) == TileSpan(columns: 1, rows: 1))
    #expect(TileSpan.default(for: .switchOutlet, on: .overview) == TileSpan(columns: 1, rows: 1))
    #expect(TileSpan.default(for: .cover, on: .overview) == TileSpan(columns: 1, rows: 1))
    #expect(TileSpan.default(for: .lock, on: .overview) == TileSpan(columns: 1, rows: 1))
    #expect(TileSpan.default(for: .scene, on: .overview) == TileSpan(columns: 1, rows: 1))
    #expect(TileSpan.default(for: .script, on: .overview) == TileSpan(columns: 1, rows: 1))
    #expect(TileSpan.default(for: .button, on: .overview) == TileSpan(columns: 1, rows: 1))
    #expect(TileSpan.default(for: .sensor, on: .overview) == TileSpan(columns: 1, rows: 1))
    #expect(TileSpan.default(for: .binarySensor, on: .overview) == TileSpan(columns: 1, rows: 1))
    #expect(TileSpan.default(for: .unknown, on: .overview) == TileSpan(columns: 1, rows: 1))
    #expect(TileSpan.default(for: .climate, on: .overview) == TileSpan(columns: 2, rows: 1))
    #expect(TileSpan.default(for: .mediaPlayer, on: .overview) == TileSpan(columns: 2, rows: 1))
    #expect(TileSpan.default(for: .camera, on: .overview) == TileSpan(columns: 2, rows: 2))
}

/// **The two surfaces disagree, and that is the point of the parameter.** Room detail is a room you
/// have opened rather than a house you are glancing across, so media and cameras get the whole width
/// there — which is exactly what both surfaces already drew by constructing renderers by hand.
@Test func roomDetailGivesMediaAndCamerasTheWholeWidth() {
    #expect(TileSpan.default(for: .mediaPlayer, on: .roomDetail) == TileSpan(columns: 4, rows: 2))
    #expect(TileSpan.default(for: .camera, on: .roomDetail) == TileSpan(columns: 4, rows: 2))
    // Everything else is the same on both, so a tile does not change shape by being looked at from
    // a different screen without a reason.
    #expect(TileSpan.default(for: .climate, on: .roomDetail) == TileSpan(columns: 2, rows: 1))
    #expect(TileSpan.default(for: .light, on: .roomDetail) == TileSpan(columns: 1, rows: 1))
    #expect(TileSpan.default(for: .sensor, on: .roomDetail) == TileSpan(columns: 1, rows: 1))
}

// MARK: - The sizes a device can be

/// The device type defines the sizes. Nothing else does — not a device class, not today's reading.
@Test func everyDomainOffersOnlyTheSizesSomethingCanDraw() {
    #expect(TileSpan.available(for: .sensor) == [TileSpan(columns: 1, rows: 1),
                                                 TileSpan(columns: 2, rows: 1)])
    #expect(TileSpan.available(for: .mediaPlayer) == [TileSpan(columns: 1, rows: 1),
                                                      TileSpan(columns: 2, rows: 1),
                                                      TileSpan(columns: 4, rows: 2)])
    // No 1-column camera: below two columns a feed is a thumbnail of a thumbnail.
    #expect(TileSpan.available(for: .camera) == [TileSpan(columns: 2, rows: 2),
                                                 TileSpan(columns: 4, rows: 2)])
    #expect(TileSpan.available(for: .light) == [TileSpan(columns: 1, rows: 1)])
    #expect(TileSpan.available(for: .climate) == [TileSpan(columns: 2, rows: 1),
                                                  TileSpan(columns: 4, rows: 2)])
}

/// One option is not a choice — the sheet shows no control at all for these.
@Test func aDomainWithOneRenderingIsNotResizable() {
    #expect(!TileSpan.isResizable(.light))
    #expect(!TileSpan.isResizable(.lock))
    #expect(TileSpan.isResizable(.sensor))
    #expect(TileSpan.isResizable(.camera))
}

/// **A size listed here must be drawable.** If a rendering is ever withdrawn, this is what fails —
/// rather than a household discovering it by seeing a blank tile.
@Test func nothingIsOfferedThatTheDefaultsDoNotAlreadyContain() {
    for domain in Domain.allCases {
        let sizes = TileSpan.available(for: domain)
        #expect(sizes.contains(TileSpan.default(for: domain, on: .overview)),
                "\(domain) cannot draw its own overview default")
        #expect(sizes.contains(TileSpan.default(for: domain, on: .roomDetail)),
                "\(domain) cannot draw its own room-detail default")
    }
}

// MARK: - Storing a size

@Test func aSpanRoundTripsThroughItsStoredForm() {
    for span in [TileSpan(columns: 1, rows: 1), TileSpan(columns: 2, rows: 1),
                 TileSpan(columns: 2, rows: 2), TileSpan(columns: 4, rows: 2)] {
        #expect(TileSpan(stored: span.stored) == span)
    }
    #expect(TileSpan(columns: 2, rows: 1).stored == "2x1")
}

/// Unreadable is nil, never a default: a value a newer build wrote must be dropped rather than
/// silently reinterpreted as a choice this household made.
@Test func anUnreadableStoredSizeIsNothingAtAll() {
    #expect(TileSpan(stored: "") == nil)
    #expect(TileSpan(stored: "2") == nil)
    #expect(TileSpan(stored: "2x") == nil)
    #expect(TileSpan(stored: "axb") == nil)
    #expect(TileSpan(stored: "0x2") == nil)
    #expect(TileSpan(stored: "-1x2") == nil)
    #expect(TileSpan(stored: "2x1x3") == nil)
}

// MARK: - Resolution

@Test func aStoredSizeIsHonouredWhenTheDomainCanDrawIt() {
    #expect(TileSpan.resolve(stored: TileSpan(columns: 2, rows: 1), for: .sensor, on: .overview)
            == TileSpan(columns: 2, rows: 1))
}

/// **The rule that survives a build withdrawing a rendering.** A camera stored as 1×1 — a size the
/// renderer refuses on purpose — must come back as the camera's default, not vanish and not render
/// at a size nothing draws.
@Test func aStoredSizeTheDomainCannotDrawFallsBackToTheDefault() {
    #expect(TileSpan.resolve(stored: TileSpan(columns: 1, rows: 1), for: .camera, on: .overview)
            == TileSpan(columns: 2, rows: 2))
    #expect(TileSpan.resolve(stored: TileSpan(columns: 4, rows: 2), for: .light, on: .overview)
            == TileSpan(columns: 1, rows: 1))
}

/// Nothing stored is the surface's own default, which is how the two surfaces keep disagreeing about
/// media and cameras until somebody says otherwise.
@Test func nothingStoredIsTheSurfaceDefault() {
    #expect(TileSpan.resolve(stored: nil, for: .mediaPlayer, on: .overview)
            == TileSpan(columns: 2, rows: 1))
    #expect(TileSpan.resolve(stored: nil, for: .mediaPlayer, on: .roomDetail)
            == TileSpan(columns: 4, rows: 2))
}
