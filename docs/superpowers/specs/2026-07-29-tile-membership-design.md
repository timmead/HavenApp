# Tile membership: removing and adding tiles (sub-projects 3 + 4) — design

**Date:** 2026-07-29
**Status:** approved, ready for an implementation plan
**Sub-projects:** 3 and 4 of the configuration capability, designed together — see *Why one spec*

## What this is

Configuration mode gains the two halves of deciding **which devices a surface shows**: a red
*Remove from dashboard* in a tile's configuration sheet, and a dashed **+** tile at the end of each
section that offers back whatever that surface isn't showing.

Building on the foundation in `2026-07-28-configuration-foundation-design.md`: `HavenConfig` is
already the single writer, `EntityPickerRow` already exists, and configuration mode already routes a
tile's tap to its own sheet.

## Why one spec

The decomposition kept these apart as 3 and 4. They are one mechanism: what removal writes is exactly
what the picker reads, and a state expressible by one and not the other is a device the user can
strand. Designing them across a gap is how they end up disagreeing.

## Decisions

### Membership is per surface, and the surfaces are independent

Haven has two surfaces that render a room's devices:

| Surface | Renders | Where |
|---|---|---|
| overview | `.primary` | the room section on the dashboard |
| room detail | `.primary` + `.secondary` | the pushed room screen |

Removing a device from the overview says nothing about room detail, and vice versa. Each surface has
its own removal and its own **+**.

The rejected alternative was one "hidden in Haven" set. It cannot express "off the dashboard but
still one tap deeper", which is the common case: the dashboard is a summary and room detail is the
inventory, so the interesting edit is almost always about the summary alone.

### Three states, not two

Per entity, per surface, the user's decision is one of:

| Stored | Meaning |
|---|---|
| *absent* | follow curation. The default, and where nearly everything stays. |
| `hidden` | the user took it off this surface. |
| `shown` | the user put it on this surface, though curation did not. |

**`shown` is what makes the + an addition rather than an undo.** Putting a humidity sensor on the
overview grid means overriding curation *upward*; a design with only a hidden set can restore what
the user removed and nothing else, which would make the + a strictly weaker control than its icon
promises.

### `CurationTier` is untouched

Tiers stay what Home Assistant and the heuristics say. This is a separate layer applied on top —
which is where `EntityCuration`'s own doc comment says user overrides belong ("relevance ranking,
usage-based promotion and user overrides belong to the configuration sub-project, deliberately not
here"). Nothing here promotes or demotes a tier; the override answers a different question, about a
surface rather than about the entity.

### Home Assistant's own hiding is not offered

Entities HA hid (`hidden_by`) or marked as configuration/diagnostic (`entity_category`) are
`.hidden`, and the picker leaves them out. Hiding an entity in Home Assistant is the user's own
explicit act in another app, and this codebase's standing rule is that HA outranks Haven's
heuristics — `EntityCuration` says so twice and `LockTile` follows it for glyphs. A user who wants
such an entity on their dashboard un-hides it where they hid it.

This is a deliberate ceiling on the + rather than an oversight: it means the picker can never offer
a device whose absence the user themselves arranged elsewhere.

### Hiding from the overview also removes it from that room's roll-ups

Roll-ups ("3/5 lights on · All Off") already act on `overviewRefs` rather than on every entity,
deliberately: "a bulk action that silently reaches entities curation hid would be worse than no bulk
action". A user-hidden tile is the same case with a stronger claim, so it falls out of the count and
out of the action.

### The button says what it does

**Remove from dashboard** on the overview, **Remove from this room** in room detail — not *Delete*.
It takes a tile off a surface and Haven never deletes anything in Home Assistant; a button labelled
delete would promise otherwise. Red because it is the destructive action *on this screen*, and
because a red button that turns out to be reversible is a better surprise than a grey one that
isn't.

**No confirmation dialog.** One tap on the same screen's + puts it back, and a confirmation on a
reversible action is how people learn to dismiss confirmations without reading them.

## Architecture

### `SurfaceMembership` (new, HavenCore, pure)

```swift
public enum HavenSurface: String, Sendable, Codable, CaseIterable {
    case overview, roomDetail
}

public enum SurfaceMembership: String, Sendable, Codable {
    case hidden, shown
}
```

Plus the rule, as a pure function so a room's membership can be tested without a view:

```swift
public static func shows(_ entityId: String, on surface: HavenSurface,
                         tier: CurationTier,
                         override: SurfaceMembership?) -> Bool
```

- `override == .shown` → true, **except** for `.hidden` tiers, which HA or `entity_category` put
  there. A `shown` override on an HA-hidden entity cannot arise through the UI (the picker omits
  them) and is refused here too, so a hand-edited document cannot make Haven contradict Home
  Assistant.
- `override == .hidden` → false.
- no override → the tier's default for that surface: overview renders `.primary`; room detail
  renders `.primary` and `.secondary`.

### Document schema

One key per entity, alongside the `name` the foundation added:

```json
{
  "entities": {
    "light.kitchen": { "name": "Reading Lamp", "surfaces": { "overview": "hidden" } },
    "sensor.lounge_hum": { "surfaces": { "overview": "shown" } }
  }
}
```

`DashboardDocument` gains a read (`surfaceOverrides`) and a single-entity write
(`settingMembership(_:for:on:)`, where `nil` clears). The same merge discipline as `name`: an
entity's other keys survive, an emptied entity record is removed, and the schema version stays at 1
because this is additive and Haven has not shipped.

### `RoomSection`

`overviewRefs`/`detailRefs` become one method taking a surface, so the two cannot drift:

```swift
public func refs(for surface: HavenSurface) -> [DeviceRef]
```

`SectionBuilder.rooms(from:environment:)` gains `overrides: [String: [HavenSurface: SurfaceMembership]]`,
**required rather than defaulted** for the reason `environment:` is required: an omitted map means
every removal in the household silently reverts, and that failure is invisible at the call site.

### App layer

- `HomeStore.setMembership(_ entityId: String, on surface: HavenSurface, to: SurfaceMembership?) async -> HavenConfig.Outcome` — writes through `HavenConfig.update`, as every write does.
- `HomeStore.addableEntities(in room: RoomSection, on surface: HavenSurface) -> [String]` — what the picker offers: every entity in the area that the surface is not currently showing, minus the `.hidden` tier.
- `TileConfigView` gains the remove button, and needs to know which surface it was opened from —
  `Navigation.Presentation.tileConfig` carries the surface.
- `AddTileView` (new): the picker sheet, `Navigation.Presentation.addTile(areaId:surface:)`.
- `AddTilePlaceholder` (new, DesignSystem): the dashed **+** tile.
- `RoomDetailView` gains the same mode affordances; configuration mode already reaches it, since
  `Navigation` is session state and room detail is pushed inside the same stack.

## Surfaces

**The + tile.** Dashed border, centred `+`, sized as a 1×1, and shown only in configuration mode.

**One per room per surface — not one per grid.** A room section is already up to four grids (climate
hoisted above at half width, the 4-column grid, media below, cameras last) and room detail groups by
domain, so "at the end of each section" would put four + tiles in a well-equipped room, each opening
the same picker. It goes at the end of the room's **4-column grid**, which is the one every room has
and the one whose contents are miscellaneous; a room whose only devices are hoisted into their own
grids therefore renders that grid solely to hold the +.

The picker it opens is not scoped to a domain, so nothing is lost by there being one: adding a camera
and adding a light are the same act, and the added tile lands in whichever grid its domain belongs to.

**The picker.** A sheet listing what the surface isn't showing, `EntityPickerRow` per row, with the
device's Haven name in bold over its entity id — and no checkmarks, because nothing in the list is
selected: tapping adds and dismisses. A room with nothing to add says so rather than showing an
empty sheet.

**The tile sheet.** The name field, then the remove button as its own card at the bottom. Both write
immediately, as the foundation's edits do.

## Failure handling

Unchanged from the foundation: `HavenConfig.update` retries a version conflict once, reports
`notAuthorized` as an outcome and records that the user is not an admin (which closes configuration
mode), refuses to write a document it could not read, and every sheet explains a failure rather than
dismissing silently.

## Testing

**HavenCore.** `SurfaceMembership.shows` over the whole matrix — four tiers × two surfaces × three
override states — including that a `shown` override cannot resurrect a `.hidden` tier. The
`surfaces` subtree round-tripping without disturbing `name` or unknown keys. `RoomSection.refs(for:)`
against a room with a mix of tiers and overrides.

**App.** `addableEntities` excludes what the surface already shows and everything HA hid; the write
path for membership, following `HavenConfigTests`.

**Views.** The + tile, the picker with and without candidates, and the tile sheet's remove button,
on a gallery page — the two configuration sheets are already there, so this extends that page.

**And the thing the last sub-project got wrong.** Three of its ten commits fixed defects invisible to
both a build and a static render: a mode with no exit, sheets presented without `.fittedSheet()`, and
a translucent banner content slid under. So for every new sheet: presented *through the same
`.fittedSheet()` call site*, with an explicit Done, and rendered over content rather than only at
rest. `AddTileView` is a new sheet and gets all three checks.

## Out of scope

Rearranging tiles (sub-project 5), tile sizes, composite devices (sub-project 6), reordering rooms or
floors, and any editing of Home Assistant's own registry.
