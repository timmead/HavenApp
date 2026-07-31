# Rearranging a room (sub-project 5b) — design

**Date:** 2026-07-30
**Status:** approved, ready for an implementation plan
**Sub-project:** 5b — the stored order and the drag, on the grid 5a built

## What this is

In configuration mode, a room's tiles can be dragged into the order the household wants, and that
order is stored in Haven's dashboard document. A **Reset arrangement** in the room's configuration
sheet puts it back.

## Scope

- **The overview only.** Room detail groups by domain because it is an inventory; that is the
  screen's purpose, not a layout limitation.
- **Within a room only.** Moving a tile between rooms would mean rewriting its area in Home
  Assistant, and Haven never writes structure to HA.
- **Order, not size.** User-chosen tile sizes are the product definition's §8 and are not asked for.

## Decisions

### The stored order lives beside the room's other configuration

`rooms.<areaId>.order`, a list of entity ids, alongside the `temperature` and `humidity` nominations
already stored under `rooms.<areaId>`.

**Written whole on every drop.** A reorder is not expressible as a delta anyone would want to merge:
two people rearranging the same room concurrently do not want a union of their intentions, they want
the last one to win, which is what `HavenConfig.update`'s version-conflict retry already gives.

### Resolution reconciles three lists, and rule 2 is the point

The stored order is never the whole truth, because Home Assistant adds and removes entities
underneath it. One pure function decides what a room shows:

1. Stored ids **still present**, in stored order.
2. Then present ids **not in the stored order**, in default order, appended.
3. Stored ids **no longer present** are dropped.

Rule 2 is what makes the feature survive a real home. A device added in HA a month after someone
rearranged the room has to appear *somewhere obvious* — at the end — rather than vanishing (which
loses a device the user owns) or leading (which silently rearranges a room nobody touched).

Rule 3 costs nothing to get right and prevents the stored list growing forever with the ghosts of
removed devices.

### The default order moves into HavenCore

5a left the band flattening — climate, then the miscellaneous tiles, then media, then cameras — as
`orderedRefs` inside `RoomSectionView`. It moves next to the resolution rule, so "what order is this
room in" is one tested question rather than half a rule in a view and half in a function.

`RoomSection` gains the stored order the way it gained `overrides`, and `refs(for:)` returns tiles
already ordered — so a caller cannot forget to apply it.

### Dragging is the system's, not ours

`.draggable` on each placeholder and `.dropDestination` on each cell, rather than a long press and a
`DragGesture`.

The dashboard is a horizontally-paging scroll view containing a vertical scroll, and this file's
neighbour records that hand-rolled pan logic is "the exact shape of the last two gesture bugs in this
codebase". System drag and drop is arbitrated against those scroll views rather than competing with
them, and brings lift, cancellation and scroll-while-dragging — the three things a custom gesture has
to earn.

**The cost, named so it does not later read as a defect:** tiles shuffle on drop rather than parting
continuously under the finger. The iOS home-screen feel is a custom gesture, and it can be revisited
on top of a stored order that already works.

Dropping on a tile inserts the dragged tile **before** it; the `+` cell is the drop target for "put
it last". Drag exists only in configuration mode — outside it a tile has no drag at all.

### Reset, in the room's configuration sheet

**Reset arrangement** clears `order` for that room. It sits with the room's sensor pickers because
it is the same kind of thing: a decision about the room rather than about a device.

Without it the only way out of an arrangement you dislike is to drag your way out, which is exactly
when dragging is least appealing.

### No accessibility actions

Drag and drop is close to unusable with VoiceOver, and the obvious remedy — "Move earlier" / "Move
later" actions on each tile — is deliberately **not** in this sub-project. Accessibility is
deprioritised for this phase by the project's own decision, and the point is recorded here so its
absence reads as a choice rather than an oversight. It is two lines per action when the phase
changes.

## Architecture

### `TileOrder` (new, HavenCore, pure)

```swift
public enum TileOrder {
    /// The band flattening 5a used: climate, then everything miscellaneous, then media, then cameras.
    public static func defaultOrder(_ ids: [String]) -> [String]
    /// Stored order reconciled against what the room actually has — see the three rules above.
    public static func resolve(stored: [String], present: [String]) -> [String]
    /// `present` reordered so `id` sits immediately before `target`, or last when `target` is nil.
    public static func moving(_ id: String, before target: String?, in order: [String]) -> [String]
}
```

`moving` is here rather than in the drop handler because "insert before, and remove from wherever it
was" is the part with an off-by-one in it — moving a tile forward past its own old position is the
case a view would get wrong.

### `DashboardDocument`

`order(forRoom:)` and `settingOrder(_:forRoom:)`, following `settingMembership`'s discipline: merge
at every level, and clearing the last key removes the record rather than leaving a shell.

### `RoomSection` / `SectionBuilder`

`orders: [String: [String]]` joins `environment` and `overrides` as a **required** parameter, for the
same reason: an omitted map silently discards every arrangement in the household, and nothing at the
call site would say so.

### App layer

- `HomeStore.setOrder(_ ids: [String], areaId: String) async -> HavenConfig.Outcome`
- `HomeStore.resetOrder(areaId: String) async -> HavenConfig.Outcome`
- `RoomSectionView` loses `orderedRefs` to HavenCore, and gains `.draggable`/`.dropDestination`.
- `RoomConfigView` gains the reset, shown only when an order is stored.

## Testing

**HavenCore.** `resolve` over its three rules, including the case that matters — a new entity
appearing after an arrangement — and `moving` over forward, backward, first, last, and moving a tile
onto itself, which must be a no-op rather than a duplication. `defaultOrder` keeps 5a's banding.

**App.** The write path for `setOrder` and `resetOrder`, following `HavenConfigTests`.

**Views.** Rendered: a room mid-arrangement is not something a static render can show, so what gets
rendered is the *result* — a room with a stored order that is plainly not the default, and the reset
control in the room sheet with and without a stored order.

**And the honest gap.** A drag cannot be exercised by a preview or by these suites. Whether the drag
competes with the pager, whether the drop targets are reachable, and whether scroll-while-dragging
works are device questions, and this sub-project should not be called finished on green tests alone.

## Out of scope

Tile sizes, cross-room moves, room and floor reordering, room detail's grouping, and the continuous
reflow a custom gesture would give.
