# Choosing a tile's size, and a sheet that saves on Done — design

**Date:** 2026-07-30
**Status:** implemented on `feat/tile-sizes`
**Follows:** sub-projects 5a/5b (the room grid, and rearranging it)

## What this is

Two configuration changes that turned out to share a sheet:

1. A tile's rendering size becomes a user choice, from the set its device can actually draw.
2. The configuration sheet stops having a per-section **Save**. **Done** commits everything.

They are specified together because the second is a prerequisite for the first: a size picker on a
sheet that saves per-section would need its own Save button, which is the thing being removed.

## A note on notation

This document writes **columns × rows**, as `TileSpan(columns:rows:)` does. The request that prompted
it wrote rows × columns — "media player being 1x2 or 2x4" is this document's 2×1 and 4×2. Where the
picker shows a size to the user it shows a **shape**, not a string, so the ambiguity cannot reach the
screen.

## Scope

Four plans, in this order. Each is a commit; each is separately verifiable.

| # | Plan | Why here |
|---|------|----------|
| 1 | Deferred save in `TileConfigView` | Prerequisite for the picker |
| 2 | Room detail on `RoomGrid` | So both surfaces honour a span before one can be chosen |
| 3 | Sensor 2×1 and climate 4×2 | So every size exists before any size is offered |
| 4 | The size model and the picker | The feature, once nothing it lists is imaginary |

**The renderings come before the picker deliberately.** The reverse order needs the offered set to
grow plan by plan, so that a size nothing can draw is never selectable — a staging rule that exists
only as an artifact of the sequence. Built this way `available` is complete and correct the day it is
written, and the new tiles are verified in the gallery before anything can choose them.

## Plan 1 — Done saves everything

### The sheet becomes draft-and-commit

Name and size are `@State`. Dismissal commits both through **one** `HavenConfig.update` closure.

One write, not two, and that is not tidiness: every write bumps the shared record's version, so two
writes are two conflict windows and two chances for the other phone in the household to see a
half-applied edit. `HomeStore` gains a single entry point taking both fields; `rename` survives as a
wrapper over it for the callers that only have a name.

### Three behaviours worth stating, because they are asymmetric

- **Done blocks and surfaces failures.** It awaits the write and keeps the sheet open on failure, as
  the current Save does.
- **Swipe-to-dismiss saves, fire-and-forget.** A dismissed sheet has nowhere to put an error. This is
  the accepted cost of "any dismissal commits", which is itself the right default here: there is no
  Cancel affordance, so silently discarding a typed name would be loss with no warning.
- **Remove discards pending edits.** It is immediate and dismisses, so a name typed but not committed
  goes with it. Removing a tile you were mid-way through renaming is not a case worth machinery.

## Plan 2 — Room detail on `RoomGrid`

Room detail groups tiles by domain under titles, and that grouping stays: it is an inventory, and the
titles are its point. What changes is that each group's `LazyVGrid` becomes a `RoomGrid`, so a tile's
span is honoured inside its group.

**This is much smaller than 5a.** That merged four grids into one because a single drag order needed
a single sequence. This substitutes a layout inside each group and merges nothing.

Room detail gains no drag and no ordering. Arrangement remains the overview's; this plan buys only
the ability to render a chosen size.

## Plan 3 — Two new renderings

### Sensor 2×1: the value, and a day of it

Current value at the size the 1×1 gives it, with a sparkline of the last 24 hours beside it.

**`.day`, and no new range.** `HistoryRange` has no sub-day case, and adding one means touching
`cacheLifetime`, `statisticsPeriod`, the label and `usesStatistics` for a product gain that does not
exist — a 24-hour line is what a glance wants.

**Empty or absent history renders the value alone, with no chart.** `SensorModal` already refuses to
draw "an empty Chart with an arbitrary/misleading axis"; a tile has less room to explain itself, so
the same rule applies harder.

**A named fetch policy, as `CameraTile.refreshPolicy` is named:** fetched on appear, never polled,
leaning on `HistoryRange.day.cacheLifetime` (300s) and `HistoryCache`'s in-flight guard. What this
costs is one history request per wide sensor per five minutes while the dashboard is open.

It is worth being accurate about the overlap: `RoomEnvironmentHistoryView` keys its fetches by
`(entityId, range, attributeName)`, so a sparkline shares that cache **only** when the room's
nominated sensor is the same entity with no attribute. Where the room nominates a climate entity's
attribute, the tile's fetch is a second one. The policy above is what bounds it, not the cache.

### Climate 4×2

Setpoint and mode given the room to be direct controls rather than a summary — the 2×1's compact
readout is what it is because a quarter-row cannot hold more.

**As built:** the *room's* temperature leads, because that is what a thermostat is for telling you
and the compact tile can only afford one number; the setpoint becomes a control with its own two
buttons rather than a readout with steppers in a corner; and every mode the unit declares gets a
button, in the unit's own order, rather than a summary line you had to open a sheet to change.

**It must survive a room's real row height, and the fallback was wrong.** `RoomGrid` took its row
height from the tallest *single-row* subview and fell back to `GlassTile`'s 66pt *floor* when there
was none — so a room of only multi-row tiles gave a 4×2 tile 141pt. That was settled early, during
plan 2: room detail's Cameras group is all 2-row tiles by construction and hit it immediately,
rebuilding the very bug `CameraTile`'s comment records. The fallback is now 82, the height a real 1×1
renders at, and the gallery draws this tile at the resulting 173pt rather than at whatever height a
`VStack` would give it.

## Plan 4 — The size model

### The span is what is stored

`entities.<entityId>.sizes.<surface>` = `"<columns>x<rows>"`, parallel to the `surfaces.<surface>`
membership record beside it. Unparseable values are **dropped rather than defaulted**, the discipline
`surfaceOverrides` already documents: a build that adds a size must leave an older build working
rather than brick it on a value it cannot read.

A named vocabulary — small/medium/large, as the reference app in `docs/domika-analysis-and-ios-plan.md`
uses — was considered and rejected. Span is already a unique key within every domain that has more
than one rendering, so a second vocabulary would be a synonym table to keep in sync, and "medium"
would mean a different shape for a camera than for a light.

### Two pure functions join `TileSpan.default`

```swift
public static func available(for domain: Domain) -> [TileSpan]
public static func resolve(stored: TileSpan?, for domain: Domain) -> TileSpan
```

**The device type defines the sizes, and nothing else does.** Not the device class, not the reading,
not whether history happens to have loaded. A tile's shape is a decision the household made about a
device, and a decision cannot depend on a value that changes every thirty seconds — a sensor going
`unavailable` must not take its 2×1 option away and invalidate a size somebody already chose.

`resolve` falls back to `default` when a stored span is no longer offered — the same shape as
`TileOrder.resolve` and `SurfaceMembership`: what the user said, reconciled against what is possible
now, never trusted blindly.

| Domain | Sizes |
|--------|-------|
| media player | 1×1, 2×1, 4×2 |
| camera | 2×2, 4×2 |
| climate | 2×1, 4×2 |
| sensor | 1×1, 2×1 |
| everything else | 1×1 only |

A domain with one size shows no picker rather than a picker with one option.

**Every sensor is offered 2×1, including the ones with nothing to plot.** A text sensor at 2×1 gets
its value and no sparkline, exactly as a temperature sensor does before its history arrives. Drawing
degrades; the option set does not. The alternative — offering the size only to sensors that look
numeric — makes what the sheet shows depend on a device class Home Assistant can change underneath
it, to save a user from a layout they chose and can undo in two taps.

### One place names the renderer variants

Today a tile's size is two facts in two places: `TileSpan.default(for:)` says how many cells, and
`RoomSectionView` separately constructs `MediaPlayerTile(size: .wide)` and `CameraTile(size: .square)`.
They agree by hand.

`MediaTileSize` and `CameraTileSize` stop appearing at call sites. Both surfaces route through one
span-aware dispatcher that maps `(domain, span)` to the rendering. This is what makes `available`
trustworthy rather than a second list to keep in sync — and it is why the dispatcher change belongs
with the storage work rather than after it.

### The picker

In `TileConfigView`, a row of shape chips — the tile's proportions drawn, not `"2x1"` written. The
current size is selected; choosing another only updates `@State` until Done, per plan 1.

## What the user should expect, so it does not read as a defect

**Widening a tile reflows its room, and can leave holes.** `GridPacking` never backfills — a tile
that does not fit in what remains of a row starts the next one, and the skipped columns stay empty.
That is the property that keeps a dragged order honest, and it is why density was traded away in 5a.

## Testing

**HavenCore.** `available` over every domain, including that it does not vary with anything else;
`resolve` including a stored span that is no longer offered falling back to the default, and a
stored span that never parsed. `settingSize` merging at every level, and clearing the last key
removing the record rather than leaving a shell — as `settingMembership`'s tests do.

**App.** The combined write asserting **one** write carrying both name and size, not two. Remove
discarding a pending name. A failed write leaving the sheet open.

**Rendered.** Sensor 2×1 with a series, with empty history, and holding a non-numeric value; climate 4×2 at both its designed
height and at the 66pt fallback; the sheet with a picker and without one; a room detail group
containing tiles of two different spans.

**The honest gap.** Whether the 4×2 climate tile reads well in a real room, and whether sparklines on
several sensors feel like information or noise, are device questions. As with 5b, this should not be
called finished on green suites alone.

## Out of scope

Ordering on room detail, sizes for the domains that have one rendering, a sub-day history range, and
per-user sizes — the dashboard document is the household's, and a size is part of it.
