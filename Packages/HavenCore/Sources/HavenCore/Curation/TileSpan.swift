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

    /// The canonical stored form, `"<columns>x<rows>"`.
    ///
    /// A shape written down rather than a name. Small/medium/large was considered and rejected: a
    /// span is already unique within every domain that has more than one rendering, so a vocabulary
    /// would be a synonym table to keep in step — and "medium" would mean a different shape for a
    /// camera than for a light.
    public var stored: String { "\(columns)x\(rows)" }

    /// A stored form back into a span, or nil if it is not one.
    ///
    /// **Nil rather than a default**, so a value written by a build that knows a size this one does
    /// not is dropped and the domain's default applies — the discipline `surfaceOverrides` already
    /// documents. Defaulting a value we cannot read would silently claim the household chose it.
    public init?(stored: String) {
        let parts = stored.split(separator: "x")
        guard parts.count == 2,
              let columns = Int(parts[0]), let rows = Int(parts[1]),
              columns > 0, rows > 0 else { return nil }
        self.init(columns: columns, rows: rows)
    }

    /// This span narrowed to fit a grid `columns` wide.
    ///
    /// Clamped rather than refused. A renderer asking for six columns of a four-column grid is a
    /// mistake in that renderer, and the useful response is the widest thing that fits — a dropped
    /// tile is a device the user owns silently disappearing from their home.
    public func clamped(toWidth columns: Int) -> TileSpan {
        TileSpan(columns: Swift.min(self.columns, Swift.max(1, columns)), rows: rows)
    }

    /// The size a domain's tile renders at on a surface, before the household chooses otherwise.
    ///
    /// Exactly what each renderer already draws on that surface, so adopting the grid changes where
    /// tiles go and never how big they are.
    ///
    /// **The surface is a parameter because the two disagree, and always did.** A media player is
    /// half a row on the dashboard and full-bleed in room detail; a camera is 2×2 there and 4×2
    /// here. That was previously encoded by each surface constructing the renderer with a size by
    /// hand, which is exactly the arrangement that lets the two facts drift apart.
    ///
    /// A function rather than a stored table because user-chosen sizes layer on top of it, the way
    /// `SurfaceMembership` layers over `CurationTier`: this stays the answer when nobody has said
    /// anything.
    ///
    /// The `switch` is exhaustive with no `default`, so a new `Domain` case fails to compile here
    /// rather than silently rendering as 1×1.
    public static func `default`(for domain: Domain, on surface: HavenSurface) -> TileSpan {
        switch domain {
        case .light, .switchOutlet, .cover, .lock, .scene, .script, .button,
             .sensor, .binarySensor, .unknown:
            return TileSpan(columns: 1, rows: 1)
        // Half a row: a target temperature and a mode is more than a quarter-width tile can say.
        case .climate:
            return TileSpan(columns: 2, rows: 1)
        // **Room detail gives media the whole width.** The dashboard is a glance across a house and
        // a track title with a transport is enough; a room you have opened is a room you are in, and
        // there the artwork-and-volume rendering is what the design gives the space to.
        case .mediaPlayer:
            switch surface {
            case .overview: return TileSpan(columns: 2, rows: 1)
            case .roomDetail: return TileSpan(columns: 4, rows: 2)
            }
        // A picture too small to recognise a person in is not a camera tile — see `CameraTileSize`,
        // which refuses to render one below two columns at all. Room detail goes full-bleed for the
        // same reason media does.
        case .camera:
            switch surface {
            case .overview: return TileSpan(columns: 2, rows: 2)
            case .roomDetail: return TileSpan(columns: 4, rows: 2)
            }
        }
    }

    /// Every size a domain can be drawn at, smallest first, or a single entry when it has one.
    ///
    /// **A function of the device type and nothing else.** Not the device class, not the reading,
    /// not whether history happens to have loaded. The size of a tile is a decision the household
    /// made about a device, and a decision must not depend on a value that changes every thirty
    /// seconds — a sensor going unavailable taking away its own 2×1 would invalidate a layout
    /// somebody chose, to save them from a layout they can undo in two taps.
    ///
    /// **Nothing is listed that cannot be drawn.** Each entry corresponds to a real rendering; when
    /// one is added, it is added here — `nothingIsOfferedThatTheDefaultsDoNotAlreadyContain` is what
    /// fails if a rendering is ever withdrawn without this list following it.
    public static func available(for domain: Domain) -> [TileSpan] {
        switch domain {
        case .light, .switchOutlet, .cover, .lock, .scene, .script, .button, .binarySensor, .unknown:
            return [TileSpan(columns: 1, rows: 1)]
        // A reading, or a reading over a day of itself — see `SensorSparkline`.
        case .sensor:
            return [TileSpan(columns: 1, rows: 1), TileSpan(columns: 2, rows: 1)]
        // A readout with two controls squeezed beside it, or the sheet's controls without the
        // sheet — see `ClimateTile`.
        case .climate:
            return [TileSpan(columns: 2, rows: 1), TileSpan(columns: 4, rows: 2)]
        case .mediaPlayer:
            return [TileSpan(columns: 1, rows: 1), TileSpan(columns: 2, rows: 1),
                    TileSpan(columns: 4, rows: 2)]
        // No 1-column camera, deliberately: below two columns a feed is a thumbnail of a thumbnail.
        case .camera:
            return [TileSpan(columns: 2, rows: 2), TileSpan(columns: 4, rows: 2)]
        }
    }

    /// Whether a domain is worth showing a size control for at all.
    ///
    /// One option is not a choice, and a picker holding a single selected chip is a control that
    /// cannot act — which this app omits rather than disables.
    public static func isResizable(_ domain: Domain) -> Bool { available(for: domain).count > 1 }

    /// A stored size reconciled against what the domain can actually draw.
    ///
    /// Falls back to the surface's default when the stored span is not among the available ones —
    /// the same shape as `TileOrder.resolve` and `SurfaceMembership`: what the household said,
    /// reconciled against what is possible now, never trusted blindly. A build that withdraws a
    /// rendering must leave every dashboard that chose it working.
    public static func resolve(stored: TileSpan?, for domain: Domain,
                               on surface: HavenSurface) -> TileSpan {
        guard let stored, available(for: domain).contains(stored) else {
            return `default`(for: domain, on: surface)
        }
        return stored
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
