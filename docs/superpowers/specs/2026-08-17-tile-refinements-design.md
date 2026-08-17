# Tile Refinements — Design

**Date:** 2026-08-17
**Status:** Approved in discussion; this document is the record of it.

Four small items from hands-on use of the subsections feature: one diagnosed rendering bug and
three tile-level refinements. Nothing here touches the subsection construct, the per-surface
size/order model, or the drag machinery.

## 1. The wide camera renders shorter than the cell it occupies (bug, diagnosed)

`CameraTile.wide` hard-codes `height: CGFloat = 141` (`CameraTile.swift:198`). A two-row cell is
~173pt, and the 2×2 `square` variant measures naturally taller — so switching a camera subsection
from 2×2 to 4×2 visibly shrinks the tile. This is the exact defect `RoomGrid.fallbackRowHeight`'s
doc comment memorializes; the comment survived, the constant did too. It was masked before
subsections because room detail rendered wide cameras in an all-wide group where nothing taller
sat beside them for comparison.

**Fix:** the wide variant fills the height the grid proposes (`maxHeight: .infinity` within the
cell) instead of asserting its own. Both layout paths already propose the correct two-row height —
`RoomGrid.placeSubviews` exactly, and `SubsectionView.tileHeight` via `unmeasuredHeight` in scroll
mode. The 141 constant and the comment above it are replaced by the reason the tile must never
assert a height again, cross-referencing the `RoomGrid` history.

## 2. A tile can go unlabelled

A new toggle in the tile config sheet, under the name field: **"Show name on tile"**, default on —
phrased as what it does, not as "no label". Semantics:

- **Storage:** `entities.<id>.label: "hidden"` in the household document — explicit vocabulary in
  the style of `state_style`, absent meaning shown. Not an empty-string sentinel through `name`:
  the name and the label-visibility are different facts, and a household that hides a label has
  not renamed anything.
- **Scope:** the visible name on tile renderings only. The control modal, pickers, add-tile list,
  and the config sheet itself always show the name — an unlabelled device must stay findable.
  Accessibility labels keep the name.
- **Sheet behaviour:** deferred-save like every sibling field; the dirty-check lives in the
  extracted edit value (`TileConfigView`'s equivalent of `SubsectionConfigEdit` treatment is NOT
  required — the existing private dirty-check pattern is the file's current idiom; the toggle
  joins it, and the precedent note already on the file covers the future extraction).
- Merge-only mutator, nil-clears, no-husk, legacy-tolerant reads — the standing document
  discipline, with the standing tests.

## 3. Media spans become 2×1, 4×1, 4×2

`TileSpan.available(for: .mediaPlayer)` changes from `[1×1, 2×1, 4×2]` to `[2×1, 4×1, 4×2]`.

- The 1×1 `.small` rendering (centred play/pause) is **deleted** — the smallest media tile is now
  the 2×1 scrolling-title `.wide`, and `MediaTileSize(span:)`'s fallback becomes `.wide`. The
  "no size is a pure launcher" rule holds: every remaining size carries at least play/pause.
- **New 4×1 rendering** (`.row`): a full-width single row — icon, then the title in the scrolling
  window taking the flexible middle, then a real transport cluster (previous / play-pause / next)
  on the right. No artwork, no volume: one row's worth of the things you do from across the room.
- Defaults are untouched (overview 2×1, room detail 4×2), so the `defaultSpan ∈ availableSpans`
  invariant holds without changes.

## 4. Climate gains a 4×1

`TileSpan.available(for: .climate)` changes from `[2×1, 4×2]` to `[2×1, 4×1, 4×2]`.

- **New 4×1 rendering** (`ClimateTileSize.row`): the current reading and state word on the left
  (the 2×1's readout, given room to breathe), the target steppers and the mode row inline on the
  right — the sheet's top strip as a tile. No second row, no history.
- Defaults untouched (2×1 both surfaces); invariant holds.

## Cross-cutting

- Every span-list change lands with its rendering in the same task — `available(for:)`'s own rule
  ("nothing is listed that cannot be drawn").
- `TileGallery` gains fixtures for both new renderings (all relevant states) and the wide-camera
  fix is verified against the existing camera fixtures — the 2×2/4×2 pair side by side is the
  regression picture for item 1.
- Subsection sizing means a kind's whole subsection renders at one span; nothing here changes
  that — these items only change which spans a household may pick and what they look like.

## Out of scope

The bulk-failure surface-keying (follow-up 9), the `#Preview` duplication (follow-up 10), and any
change to camera span offerings (2×2/4×2 stay as they are).
