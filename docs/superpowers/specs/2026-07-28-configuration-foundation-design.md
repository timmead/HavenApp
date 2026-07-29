# Configuration foundation (sub-project 1) — design

**Date:** 2026-07-28
**Status:** approved, ready for an implementation plan
**Sub-project:** 1 of 6 in the configuration capability (see *Decomposition* below)

## What this is

The first slice of Haven's configuration capability: an explicit configuration mode, the shared
write path that every later configuration feature will use, and two things a user can actually
change — a room's temperature and humidity sources, and a device's display name.

The product definition (§8, §10) already commits to configuration mode as a first-class pillar:
explicit mode, registry auto-generation to a good default, configuration to make it exactly yours,
then never think about it again. This is the foundation that everything else in §10 stands on.

## Decomposition (agreed)

| # | Sub-project | Depends on |
|---|---|---|
| 1 | **Config foundation** — this document | — |
| 2 | Room configuration | folded into 1 |
| 3 | Tile editing: remove-from-dashboard, the hidden set | 1 |
| 4 | Adding tiles: the "+" affordance and its picker | 1, 3 |
| 5 | Rearranging: single-grid rebuild plus drag and drop | 1 |
| 6 | Composite devices: tiles fed by several entities | 1, 3 |

Renaming was pulled forward from 3 into 1 deliberately: it is one string, fully reversible, and
cannot make a control vanish, so it exercises the write path without requiring removal semantics to
be settled first. Removal stays in 3, next to the hidden set it writes — which is the same set
sub-project 4's "+" picker reads back, so the two are designed against one another rather than
across a gap.

## What already exists

Almost all of the persistence layer, idle and waiting:

- **`DashboardDocument`** wraps the raw stored JSON and merges rather than replaces, preserving keys
  written by builds that know more than this one. Its own doc comment names this work: "today,
  which of a room's several temperature sources is *the* room's; later, tile positions, labels and
  composite-device definitions."
- **`HavenConfigRecord` / `HavenConfigWrite`** model the versioned record and the
  `version_conflict` outcome the integration returns as data rather than as an error.
- **`EnvironmentCoordinator`** already performs a full load → resolve → merge → save with a
  version-conflict retry against the `shared` scope.
- **`RoomEnvironment.candidates(for:)`** is public specifically so a configuration picker has
  something to render: "a resolver that only returned the winner would leave it with nothing to
  show."
- **`HomeConnection.fetchCurrentUserIsAdmin`** exists; onboarding uses it, the running session does
  not yet.

## Decisions

Each of these was a real fork; the reasoning is recorded so a later reader does not have to
re-derive it.

### Configuration mode is hidden unless the user is a confirmed admin

The `shared` scope is writable by Home Assistant admins only — the integration answers
`not_authorized` to anyone else, and that is an expected steady state for a household member, not a
fault.

`fetchCurrentUserIsAdmin` has three answers: yes, no, and "we could not find out". The entry point
appears **only for yes**. The accepted cost, stated so it is not later mistaken for a bug: if the
admin check fails, a genuine admin has no configuration entry until the next successful connect.
The alternative — showing it on unknown — trades that for a household member reaching a dead end,
and this app's standing rule is to omit a control that cannot act rather than to offer one that
looks live.

### Automatic nomination is priming, not a mode

Haven proposes a room's temperature and humidity sources on first sight and writes them down. After
that they are ordinary stored values. There is therefore no "Automatic" entry in the picker to
return to, and no "None": the picker offers the room's candidate sources and nothing else.

This is what makes room configuration need **no new schema at all** — a user's pick is written to
exactly the place, and in exactly the shape, that an auto-proposal already writes.

### A renamed device is renamed in Haven, never in Home Assistant

Home Assistant stays the source of truth for structure. A display name is Haven's own override,
stored in Haven's document, resolved above `friendly_name`.

The consequence is deliberate and must be visible in the UI: an override **shadows Home Assistant
permanently**. Rename an entity in HA afterwards and Haven goes on showing the override. That is
the right precedence — an explicit choice outranks a default — but it means the rename sheet shows
what HA calls the device underneath, so an override reads as an override rather than as a mystery,
and offers a reset.

### The document's schema version is *not* bumped

**Haven has not shipped.** There is no older build in anyone's household, no stored document in the
wild, and therefore no migration to write and no compatibility to preserve. Adding `entities` needs
no version signal because there is nothing to signal it to.

`DashboardDocument.schema` stays at 1 and `isWritable` stays as it is — both are already
implemented, cost nothing, and start earning their keep the day there are two builds in one house.
The rule for when a bump *is* warranted can be settled then, against a real first shipped version,
rather than guessed at now.

### One writer per document

Two components each doing read-modify-write against one versioned record means two retry loops
racing, and the loser silently reapplies stale state. All writes go through one component.

### Writes happen per edit, not batched on exit

Every edit here is a single key and the document merges per key, so an interrupted session leaves
the edits already made rather than losing all of them. Batching would mean one version bump instead
of several, at the cost of a dirty-state model and a crash discarding the lot. Version churn is the
cheaper failure.

## Architecture

### `HavenConfig` (new, App layer, `@Observable`)

Owns Haven's dashboard document and every write to it.

- `load(...)` — reads the `shared` record at bootstrap, keeping both the document and its version.
- `isLoaded` — whether the document was read successfully. Distinguishes "no configuration yet"
  (an ordinary first run, `nil` record) from "we could not find out" (a throw). The distinction is
  load-bearing: see the gating rules.
- `isWritable` — the document's own `isWritable`, false when a newer build wrote it.
- `isAdmin` — from `fetchCurrentUserIsAdmin`, fetched once per connect.
- `update(_ mutate: (DashboardDocument) -> DashboardDocument) async throws` — the single write
  entry point. Merges, saves against the held version, and on `versionConflict` refetches, reapplies
  the same mutation to the *current* document, and retries once.

`EnvironmentCoordinator` keeps nomination resolution — which is a domain rule, not a storage
concern — and routes its proposal write-backs through `HavenConfig.update` instead of owning a
second write path. This is a refactor of existing behaviour, not a change to it; the existing
write-back tests must continue to pass unchanged.

### `Navigation`

Gains an editing flag and replaces `presentedEntityId` with one presentation enum:

```swift
enum Presentation: Equatable {
    case control(entityId: String)
    case tileConfig(entityId: String)
    case roomConfig(areaId: String)
}
```

One presented value means two sheets cannot contend for the screen. Configuration mode lives here
rather than in `DashboardView`'s own state because `Navigation` is session-scoped: a sign-out,
reauthentication or reconnect drops configuration mode on the way past, which is the behaviour we
want and would otherwise have to remember to write.

### `DisplayName` (new, HavenCore, pure)

```
Haven override → HA friendly_name → derived from the entity id
```

A pure function with tests rather than a chain inside a view, because it is a rule the whole app
must agree on: tiles, modals, and every picker row. `TileName.of` calls it.

An override that is empty or whitespace-only is treated as absent, so clearing the field resets to
Home Assistant's name rather than rendering a blank tile.

## Schema

The document gains one top-level subtree. `rooms` is untouched.

```json
{
  "schema": 1,
  "rooms": {
    "<area_id>": {
      "temperature": { "entity_id": "sensor.x", "source": "state" },
      "humidity":    { "entity_id": "climate.y", "source": "attribute", "attribute": "current_humidity" }
    }
  },
  "entities": {
    "light.kitchen": { "name": "Reading Lamp" }
  }
}
```

`entities` is keyed by entity id and lives at the document root rather than under a room, because an
entity's name does not depend on which room it is in — moving a device between areas in Home
Assistant must not silently lose the name a user gave it.

## Surfaces

### The mode shell

Entry is a menu item in the dashboard's existing top-right menu, beside Connection and Sign Out,
shown only to a confirmed admin. Exit is a Done control in the toolbar.

In configuration mode: a tile's tap opens its configuration instead of its control modal, a room
title opens room configuration, and long-press does nothing. A persistent strip states that the
dashboard is being edited — the mode must be legible at a glance, since every tap means something
different while it is on.

**Two rules that make the mode refuse rather than mislead.** It cannot be entered when the document
failed to load, because editing over a document we could not read is how a household's
configuration gets overwritten — `EnvironmentCoordinator` already refuses to *propose* for exactly
this reason. It cannot be entered while disconnected, because every edit is a write.

### Room configuration

A sheet titled with the room, with a section per role: Temperature, then Humidity. Each lists
`candidates(for:)` in the resolver's own rank order, with the current pick checked. Tapping a
candidate writes it immediately.

Attribute sources appear alongside sensor entities. They must: Haven auto-nominates a thermostat's
`current_temperature` in rooms with no dedicated sensor, so omitting them would leave a user unable
to re-select what the app had already chosen for them.

### Tile configuration

For this sub-project the sheet holds one field: the display name, with what Home Assistant calls
the device shown beneath it, and a reset that appears only when an override exists. Sub-project 3
adds removal to this sheet; sub-project 6 adds entity binding.

### `EntityPickerRow` (new, App layer)

A shared row: the display name in bold — resolved through `DisplayName`, so a renamed device reads
that way in pickers too — and the entity id on a second line. For an attribute source the second
line names the attribute alongside the entity id, since the entity alone would not say which
reading is meant.

Built as a component taking a list rather than as part of the room sheet, because sub-projects 3, 4
and 6 all need the same row and should not each grow their own. No search in this sub-project: the
lists here are one room's candidates, and a component that takes a list can gain search when the
add-tile picker needs it.

## Failure handling

| Situation | Behaviour |
|---|---|
| Version conflict on write | Refetch, reapply the same mutation to the current document, retry once. The existing pattern. |
| `not_authorized` on write | Explain and leave configuration mode — admin status changed under us. |
| Document failed to load | Configuration mode unavailable. |
| Disconnected | Configuration mode unavailable. |
| Document written by a newer build | Configuration mode unavailable (`isWritable == false`). Unreachable before launch — there is no newer build — but the check already exists and costs nothing to honour. |

## Testing

**HavenCore.** The `entities` subtree round-trips; a document carrying unknown top-level keys and
unknown keys *inside* an entity keeps them across a name write — the property
`DashboardDocumentTests` exists to defend, extended to the new subtree. `DisplayName` precedence,
including that an empty or whitespace override is treated as absent.

**App.** The write path's conflict-retry, following `DashboardConfigWriteBackTests`. The gating
rules — not loaded, not connected, not admin, not writable — each denying entry. That
`EnvironmentCoordinator`'s existing write-back behaviour is unchanged by the refactor, which its
current tests already assert.

**Views.** The two sheets and the picker row are view code with no test coverage, so they are
verified by rendering, as `TileGallery` and the lock modal's preview are. A preview page covering:
a room with several candidates, a room with only an attribute source, a room with none, a device
with an override, and one without.

## Out of scope

Removal and the hidden set, the "+" tile, drag-to-rearrange, tile sizes (1×1 / 2×1 / 2×2),
composite devices, per-user configuration overlays, and reordering floors or rooms. Each belongs to
a later sub-project in the table above.
