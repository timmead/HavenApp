import Foundation

/// How many cells of a room's grid a tile occupies.
///
/// **A value, not an enum of the three sizes in use.** Today every tile is 1×1, 2×1 or 2×2, and an
/// enum would be tidier — but 4×1 and 4×2 renderings are foreseeable, and `MediaPlayerTile.large`
/// *already is* 4×2 in room detail. An enum would need widening, along with every `switch` over it,
/// the first time one of those reached the overview.
public struct TileSpan: Sendable, Equatable, Hashable {
    public let columns: Int
    public let rows: Int

    /// Both are floored at 1: a tile occupying no cells cannot be placed, cannot be tapped, and
    /// cannot be told apart from a tile that failed to render.
    public init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }

    /// This span narrowed to fit a grid `columns` wide.
    ///
    /// Clamped rather than refused. A renderer asking for six columns of a four-column grid is a
    /// mistake in that renderer, and the useful response is the widest thing that fits — a dropped
    /// tile is a device the user owns silently disappearing from their home.
    public func clamped(toWidth columns: Int) -> TileSpan {
        TileSpan(columns: Swift.min(self.columns, Swift.max(1, columns)), rows: rows)
    }

    /// The size a domain's tile renders at.
    ///
    /// Exactly what each renderer already draws, so adopting the grid changes where tiles go and
    /// never how big they are.
    ///
    /// A function of the domain rather than a stored table because user-chosen sizes — the product
    /// definition's "default sizes are per-domain and user-overridable" — layer on top of it, the
    /// way `SurfaceMembership` layers over `CurationTier`: this stays the answer when the user has
    /// said nothing.
    ///
    /// The `switch` is exhaustive with no `default`, so a new `Domain` case fails to compile here
    /// rather than silently rendering as 1×1.
    public static func `default`(for domain: Domain) -> TileSpan {
        switch domain {
        case .light, .switchOutlet, .cover, .lock, .scene, .script, .button,
             .sensor, .binarySensor, .unknown:
            return TileSpan(columns: 1, rows: 1)
        // Half a row: a target temperature and a mode, or a track title and a transport, are more
        // than a quarter-width tile can say.
        case .climate, .mediaPlayer:
            return TileSpan(columns: 2, rows: 1)
        // A picture too small to recognise a person in is not a camera tile — see `CameraTileSize`,
        // which refuses to render one below two columns at all.
        case .camera:
            return TileSpan(columns: 2, rows: 2)
        }
    }
}

/// Where one tile sits in the grid.
public struct GridPlacement: Sendable, Equatable {
    public let column: Int
    public let row: Int
    /// The span *as placed* — already clamped to the grid's width, so a consumer never has to
    /// re-apply that.
    public let span: TileSpan

    public init(column: Int, row: Int, span: TileSpan) {
        self.column = column; self.row = row; self.span = span
    }
}

/// Fitting a room's tiles into a fixed number of columns.
///
/// A pure function rather than arithmetic inside a `Layout`, because this is the part with rules in
/// it and a `Layout` is not somewhere a test can reach.
public enum GridPacking {
    /// Places `spans` in order, left to right and top to bottom.
    ///
    /// **Sequential, and it never backfills.** A tile that does not fit in what remains of the
    /// current row starts the next one, and the columns it skipped stay empty for good — a later
    /// 1×1 will not drop into them.
    ///
    /// That wastes space, deliberately. This sequence is what the user rearranges by dragging, so
    /// **the order they set has to be the order they see**; a packer that reached forward for
    /// something that fits would put a tile dropped in fourth place somewhere other than fourth.
    /// Density is worth less than an arrangement that agrees with itself.
    public static func place(_ spans: [TileSpan], columns: Int) -> [GridPlacement] {
        let width = max(1, columns)
        var placements: [GridPlacement] = []
        /// How many rows each column is still occupied for, counted from the current row. A tall
        /// tile is the only reason this is not all zeroes.
        var blocked = [Int](repeating: 0, count: width)
        var row = 0
        var column = 0

        func advanceRow() {
            row += 1
            column = 0
            blocked = blocked.map { max(0, $0 - 1) }
        }

        for span in spans {
            let span = span.clamped(toWidth: width)
            while true {
                // Skip columns a tall tile from an earlier row is still occupying.
                while column < width && blocked[column] > 0 { column += 1 }
                let fits = column + span.columns <= width
                    && !(column..<min(column + span.columns, width)).contains(where: { blocked[$0] > 0 })
                if fits { break }
                advanceRow()
            }
            placements.append(GridPlacement(column: column, row: row, span: span))
            for c in column..<(column + span.columns) {
                blocked[c] = span.rows
            }
            column += span.columns
        }
        return placements
    }

    /// How many rows a packing needs.
    ///
    /// The *extent* of each placement, not the row it starts in: a room ending in a 2×2 needs the
    /// row below that tile's origin too, and counting starts alone would draw the grid an entire row
    /// short of its own content.
    public static func rowCount(_ placements: [GridPlacement]) -> Int {
        placements.reduce(0) { max($0, $1.row + $1.span.rows) }
    }
}
