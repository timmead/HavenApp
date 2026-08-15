import SwiftUI
import HavenCore

/// One room's tiles, in a fixed number of columns, with tiles that can span more than one cell.
///
/// **A `Layout` rather than a `LazyVGrid`, because spans are the entire requirement.**
/// `.gridCellColumns(_:)` is inert inside a `LazyVGrid` — which is why a room used to be four
/// separate grids, one per width, and why nothing could be dragged from one part of a room to
/// another. Where each tile goes is `GridPacking`'s decision, in HavenCore with tests; this places
/// what that returns.
///
/// **It is not lazy, and that is the cost.** A `LazyVGrid` builds only what is on screen; a `Layout`
/// measures every subview it is given. A room holds a handful of tiles so this is comfortably fine
/// here — but it is exactly why this is a *room's* grid and not a floor's.
struct RoomGrid: Layout {
    var columns: Int = 4
    var spacing: CGFloat = 9

    /// The row height when there is nothing single-row to measure.
    ///
    /// **Not `GlassTile`'s 66pt floor, which is the trap this grid exists to have escaped.** 66 is a
    /// minimum; a real 1×1 tile renders nearer 82 because its content needs the room, and
    /// `CameraTile` records what assuming the floor cost — a hard-coded 141 that made every camera
    /// shorter than the two rows it claimed to occupy.
    ///
    /// A grid with nothing single-row in it is not hypothetical: room detail groups by domain, so
    /// its Cameras group is *all* 2-row tiles and has nothing to measure. Falling back to the floor
    /// there would have quietly rebuilt the same bug on the other surface.
    static let fallbackRowHeight: CGFloat = 82

    struct Cache {
        var placements: [GridPlacement]
        var rowHeight: CGFloat
        var rowCount: Int
    }

    func makeCache(subviews: Subviews) -> Cache { cache(for: subviews) }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = self.cache(for: subviews) }

    private func cache(for subviews: Subviews) -> Cache {
        let spans = subviews.map { $0[TileSpanKey.self] }
        let placements = GridPacking.place(spans, columns: columns)
        return Cache(placements: placements,
                     rowHeight: rowHeight(subviews: subviews, placements: placements),
                     rowCount: GridPacking.rowCount(placements))
    }

    /// **Measured, never assumed.**
    ///
    /// The obvious row height is `GlassTile`'s `minHeight` of 66, and `CameraTile` used to hard-code
    /// its own height as two of those plus spacing. But 66 is a *floor*: a lock or a thermostat
    /// renders nearer 82 because its content needs the room. A grid built on 66 would therefore
    /// shrink almost every tile in the app, which is the one direction this rebuild must not go.
    ///
    /// Only *single-row* tiles are measured. A tall tile's ideal height is a function of the row
    /// height, so letting it vote would be circular — and a room with one camera and a room with a
    /// camera and a light would end up with different row heights for the same camera.
    ///
    /// **Every tile therefore has to measure as what it draws, and this is where a tile that does
    /// not shows up.** One single-row tile reporting an inflated ideal height makes *every* row in
    /// the room that tall. `SensorTile`'s sparkline did exactly that: a `Chart` has a large ideal
    /// height, and as a `ZStack` member it handed that to its parent — so putting one sensor on a
    /// dashboard grew every tile beside it, and only once its history had loaded. A background
    /// rather than a stack member was the fix, and the same hazard applies to anything with an
    /// opinion about its own size: charts, images with an aspect ratio, maps.
    private func rowHeight(subviews: Subviews, placements: [GridPlacement]) -> CGFloat {
        let singleRow = zip(subviews, placements)
            .filter { $0.1.span.rows == 1 }
            .map { $0.0.sizeThatFits(.unspecified).height }
        return max(singleRow.max() ?? Self.fallbackRowHeight, Self.fallbackRowHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 0
        let height = cache.rowCount == 0
            ? 0
            : CGFloat(cache.rowCount) * cache.rowHeight + CGFloat(cache.rowCount - 1) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout Cache) {
        guard columns > 0 else { return }
        let columnWidth = self.columnWidth(inContainerOfWidth: bounds.width)
        for (subview, placement) in zip(subviews, cache.placements) {
            let width = self.width(for: placement.span, inContainerOfWidth: bounds.width)
            let height = cache.rowHeight * CGFloat(placement.span.rows)
                + spacing * CGFloat(placement.span.rows - 1)
            let x = bounds.minX + CGFloat(placement.column) * (columnWidth + spacing)
            let y = bounds.minY + CGFloat(placement.row) * (cache.rowHeight + spacing)
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          // Exact rather than a range: a tile that decided its own height would put
                          // the grid's rows out of step with the cells it just computed.
                          proposal: ProposedViewSize(width: width, height: height))
        }
    }

    // MARK: - The cell arithmetic, for callers that place tiles themselves

    /// What one column is worth in a container `containerWidth` across.
    ///
    /// **Exposed rather than kept inside `placeSubviews`** because `SubsectionView`'s scroll body
    /// lays its tiles out in an `HStack` and has to size each one itself. The spec's promise there is
    /// that the display mode changes a subsection's *arrangement* and never its proportions — which
    /// only holds while both modes divide the width the same way, and a second copy of this formula
    /// is exactly how the two would drift apart.
    func columnWidth(inContainerOfWidth containerWidth: CGFloat) -> CGFloat {
        max(0, (containerWidth - spacing * CGFloat(columns - 1)) / CGFloat(max(1, columns)))
    }

    /// The width a tile spanning `span` occupies, the spacing between its own columns included.
    ///
    /// Clamped to the grid's width first, exactly as `GridPacking.place` clamps what it places — so a
    /// caller sizing its own tiles gets the width this grid *would have given* an over-wide span
    /// rather than one that overflows the container.
    func width(for span: TileSpan, inContainerOfWidth containerWidth: CGFloat) -> CGFloat {
        let span = span.clamped(toWidth: columns)
        return columnWidth(inContainerOfWidth: containerWidth) * CGFloat(span.columns)
            + spacing * CGFloat(span.columns - 1)
    }

    /// The height a tile spanning `span` occupies when there is **nothing single-row to measure**.
    ///
    /// That is exactly the case a multi-row subsection is in: every tile in one carries the same
    /// span, so a 2×2 cameras subsection has no single-row tile to take a row height from and this
    /// grid falls back to `fallbackRowHeight` for it (see `rowHeight(subviews:placements:)`). The
    /// scroll body has no `Subviews` to measure at all, so it asks for the same answer here rather
    /// than letting a `Chart` or an aspect-ratioed image decide how tall a camera row is.
    func unmeasuredHeight(for span: TileSpan) -> CGFloat {
        Self.fallbackRowHeight * CGFloat(span.rows) + spacing * CGFloat(span.rows - 1)
    }
}

/// How many cells a tile occupies, read by `RoomGrid`.
private struct TileSpanKey: LayoutValueKey {
    /// A tile that says nothing is one cell — the size most of them are, and a safe answer for one
    /// that has not been told about spans yet.
    static let defaultValue = TileSpan(columns: 1, rows: 1)
}

extension View {
    /// Declares how many cells of a `RoomGrid` this tile occupies.
    func tileSpan(_ span: TileSpan) -> some View {
        layoutValue(key: TileSpanKey.self, value: span)
    }
}
