# One room, one grid (sub-project 5a) — design

**Date:** 2026-07-30
**Status:** approved, ready for an implementation plan
**Sub-project:** 5a of the configuration capability — the layout rebuild that 5b's drag needs

## What this is

A room's overview becomes **one 4-column grid** whose tiles declare how many columns and rows they
occupy, replacing the four stacked `LazyVGrid`s it is built from today.

No drag, no stored order, no user-chosen sizes. Those are 5b. This is the layout that makes them
possible.

## Why it has to come first

A room section is currently four grids: climate at 2 columns, a 4-column grid of everything else,
media at 2, cameras at 2. They exist for a concrete reason recorded in the file —
`.gridCellColumns(_:)` is inert inside a `LazyVGrid`, so a 2-wide tile needs a grid that is literally
two columns wide.

Four grids cannot be dragged between. Any gesture that moves a light above a thermostat has to move
it *between containers*, which is not a reorder but a re-parent. So the grid comes first, on its own,
where it can be looked at without a gesture on top of it.

## Decisions

### Spans are values, not a fixed set of cases

`TileSpan` holds `columns` and `rows`. Not an enum of 1×1 / 2×1 / 2×2, even though those are the only
three in use today: a 4×1 or 4×2 rendering is foreseeable — `MediaPlayerTile.large` is **already**
4×2 and renders in room detail — and an enum would have to be widened, along with every switch over
it, the first time one appears on the overview.

A span wider than the grid is clamped to the grid's width rather than rejected. A tile asking for six
columns in a four-column grid is a mistake in a renderer, and the useful response is the widest thing
that fits, not a crash or an empty cell.

### The packer is sequential and never backfills

A tile goes in the next free slot at or after the previous tile's; if it does not fit in what remains
of the row, it starts the next row, and the gap it leaves stays a gap.

First-fit packing would be denser — a later 1×1 could drop into that gap — and it is the wrong
choice here for one reason: **the order the user sets must be the order the user sees.** 5b makes this
sequence draggable, and a packer that reorders means dragging a tile to the third position and
watching it appear second. Density is worth less than that.

The visible consequence today: a room whose only 2-wide tile is a thermostat currently leaves the
rest of that band empty, because the next band starts fresh. Now the next tile fills it. That is the
one intended difference in how rooms look.

### Row height is measured, not assumed

`CameraTile` hard-codes its 2×2 height as 141 — "two tile rows plus the grid's own row spacing",
i.e. an assumed 66pt row, which is `GlassTile`'s `minHeight`. But 66 is a *floor*: a lock or climate
tile renders about 82 because its content needs more. A grid with 66pt rows would therefore shrink
every 1×1 tile in the app.

So the layout derives its row height from **the tallest single-row subview it is given**, and a tile
spanning *n* rows gets `n · rowHeight + (n − 1) · spacing`. The hard-coded 141 in `CameraTile` goes
away, since the grid now owns that arithmetic and the tile only declares `2×2`.

Two consequences, stated rather than discovered:

- **A camera grows by about 30pt.** At a measured row of roughly 82 it becomes `2 × 82 + 9 = 173`
  where it is 141 today. Nothing shrinks, which is the direction that matters, but this is not a
  rounding difference and it will be visible.
- **Its still gets taller, which moves the aspect-fill overflow.** A 16:9 frame in a taller box
  overflows further horizontally — the defect that once bled camera tiles over their neighbours. That
  is already fixed structurally: the picture is an overlay on a `Color.clear`, so it cannot report an
  oversized width to its parent. This is a case for the render list, not a new risk.

**When there is no single-row subview** — a room whose only tile is a camera — there is nothing to
measure, and the row height falls back to `GlassTile`'s own 66pt floor. Deriving it from the
multi-row tile instead would let one tile define the grid it sits in, so a room with one camera and a
room with a camera and a light would use different row heights for the same camera.

### Default spans come from the domain, layered so 5b can override them

`TileSpan.default(for: Domain)` is the only source of a tile's size today:

| Span | Domains |
|---|---|
| 1×1 | light, switch, lock, scene / script / button, sensor, binary sensor, unknown |
| 2×1 | climate, media player |
| 2×2 | camera |

Exactly the widths those tiles have now, so no tile changes size in this sub-project.

It is a function of the domain rather than a constant table so that user-chosen sizes — the product
definition's §8 "default sizes are per-domain and user-overridable" — layer on top of it the way
`SurfaceMembership` layers over `CurationTier`: the default stays the answer when the user has said
nothing.

### The default order is today's order

The sequence is the four bands flattened: climate, then the miscellaneous grid, then media, then
cameras. Nothing moves except by the gap-filling above. When 5b adds a stored order, an absent one
falls back to exactly this — so a household that never rearranges anything never sees a change.

### Room detail keeps its domain groups

It groups by kind because it is an inventory — "all the lights, all the sensors" — not because
`LazyVGrid` forced it to. That screen is unchanged.

## Architecture

### `TileSpan` and `GridPacking` (new, HavenCore, pure)

```swift
public struct TileSpan: Sendable, Equatable, Hashable {
    public let columns: Int
    public let rows: Int
    public init(columns: Int, rows: Int)          // both clamped to at least 1
    public static func `default`(for domain: Domain) -> TileSpan
    /// This span narrowed to fit a grid of `columns` columns.
    public func clamped(toWidth columns: Int) -> TileSpan
}

public struct GridPlacement: Sendable, Equatable {
    public let column: Int
    public let row: Int
    public let span: TileSpan
}

public enum GridPacking {
    /// Sequential, no backfill. See the design decision above.
    public static func place(_ spans: [TileSpan], columns: Int) -> [GridPlacement]
    /// Rows needed to hold a packing — what the layout sizes itself from.
    public static func rowCount(_ placements: [GridPlacement]) -> Int
}
```

Pure and exhaustively testable, which is the point of it being here rather than inside a `Layout`:
the interesting cases are a 2-wide tile arriving at column 3, a 2×2 occupying two rows, a 4-wide
tile always starting a row, a span wider than the grid, and a gap that stays a gap.

### `RoomGrid` (new, App layer, a SwiftUI `Layout`)

A `Layout` rather than a `LazyVGrid`, because spans are the whole requirement and `LazyVGrid` cannot
express them. It reads each subview's span from a `LayoutValueKey`, asks `GridPacking` where
everything goes, and places it.

```swift
struct RoomGrid: Layout { let columns: Int; let spacing: CGFloat }
extension View { func tileSpan(_ span: TileSpan) -> some View }
```

**It is not lazy, and that is a cost to state.** `LazyVGrid` builds only what is on screen; a
`Layout` measures every subview. A room holds a handful of tiles, so this is fine here — but it is
the reason this is a *room's* grid and not a floor's.

### `RoomSectionView`

Loses four `[GridItem]` arrays and four grids, and gains one ordered sequence of refs plus one
`RoomGrid`. The **+** tile becomes a 1×1 at the end of the sequence rather than a special case inside
the fourth grid — which also retires the "render this grid even when empty so the + has somewhere to
live" special case that shipped with sub-project 4.

### `CameraTile`

Drops the hard-coded 141 and the arithmetic behind it. Its 2×2-ness is now declared once, as a span.

## Testing

**HavenCore.** `GridPacking` over the cases named above, plus `TileSpan.default(for:)` for every
`Domain` case — a `switch` with no `default` would catch a new domain at compile time, and the test
catches a wrong answer for an existing one.

**Views.** Rendered, since a layout is not otherwise verifiable: a room of 1×1s; a room with one
thermostat followed by lights, which is the gap-filling case; two cameras; a room whose tiles are all
2-wide; and a room in configuration mode, where the placeholders and the **+** must sit in the same
cells as the tiles they replace. The tile gallery gains a page.

**And the check this project keeps needing.** Every previous sub-project shipped at least one defect
that a static render could not show. For a layout the equivalent is *scrolling*: the room grid is
inside a vertical scroll view inside a horizontal pager, so the rendered page must be looked at
scrolled, not only at rest.

## Out of scope

Drag and drop, stored order, user-chosen tile sizes, room detail's grouping, and anything about
floors. 5b is drag and order; sizes are the product definition's §8 and are not asked for yet.
