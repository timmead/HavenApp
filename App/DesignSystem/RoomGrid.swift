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
    private static let fallbackRowHeight: CGFloat = 82

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
        let totalSpacing = spacing * CGFloat(columns - 1)
        let columnWidth = max(0, (bounds.width - totalSpacing) / CGFloat(columns))

        for (subview, placement) in zip(subviews, cache.placements) {
            let width = columnWidth * CGFloat(placement.span.columns)
                + spacing * CGFloat(placement.span.columns - 1)
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
