# Room Subsections — Design

**Date:** 2026-08-15
**Status:** Approved in discussion; this document is the record of it.

## What this is

Rooms stop rendering their devices as one mixed grid and start rendering them as **subsections**:
opinionated per-domain containers — Climate, Lights, Shades, Cameras, and the rest — shown on both
the floor view and the room detail view, hidden when empty, each with a household-chosen tile size
and display mode. The room detail view already groups by domain; this promotes that grouping to a
first-class construct, brings it to the floor view, and moves tile sizing from the entity to the
subsection.

Nothing here rewrites the tile renderers. They are consumed as they exist; what changes is where
their span comes from and what container arranges them.

## Decisions, and where each came from

Settled in the design discussion, recorded here so the plan doesn't re-litigate them:

1. **All seven existing groups become subsections** — Climate, Lights, Shades, Media, Cameras,
   "Scenes & more", Sensors. Not just the four named in the original idea; two rendering models in
   one room was rejected.
2. **Both surfaces render the same construct.** A floor room card is a vertical stack of subsection
   containers, exactly as room detail is. The floor variant may be more streamlined (tighter
   header, smaller spacing) — a *density* axis, not a different construct.
3. **Display mode resolves per-subsection override → household global default → built-in
   `scroll`.** Both the override and the global default are user-configurable.
4. **All new configuration lives in the shared household document** — admin-gated, optimistically
   concurrent, synced to every member. No device-local display settings.
5. **Per-entity sizing is removed outright**: the `entities.<id>.sizes` schema key, its accessors
   and mutator, and the size picker in the tile config sheet. One sizing rule — the subsection
   decides, every tile in it renders alike.
6. **Rollups move into subsection headers** on both surfaces: "All off" beside Lights, "Close all"
   beside Shades. The room heading stops carrying a button row.
7. **Default subsection order is fixed**: climate, lights, shades, cameras, media, other, sensors.
   Per-household ordering is deferred; when it comes it is one optional key, no migration.
8. **Configure mode forces every subsection to wrap.** Rearranging happens on a grid, never in a
   scroll row: entering edit mode temporarily renders each subsection in wrap mode regardless of
   its configured display mode, which lets the existing drag-to-reorder machinery be reused
   unchanged. Leaving edit mode restores the configured mode.

## Schema

Two additions to the dashboard document, one deletion. Schema stays at 1.

```json
{
  "schema": 1,
  "display": { "mode": "scroll" },
  "subsections": {
    "climate":  { "size": "4x2", "mode": "wrap" },
    "cameras":  { "size": "2x2" }
  }
}
```

- `subsections.<kind>` — one object per kind, every key optional, absent kinds meaning "all
  defaults". Kinds are the closed set `climate`, `lights`, `shades`, `media`, `cameras`, `other`,
  `sensors`. `size` uses the existing `"CxR"` span vocabulary; `mode` is `"scroll"` or `"wrap"`.
- `display.mode` — the household's global default mode. A separate top-level object rather than a
  pseudo-kind inside `subsections`, so kind keys stay a closed enum.
- **Deleted:** `entities.<id>.sizes`, `settingSize`, the `sizes` accessor, and every read of
  per-entity spans. No migration — nothing has shipped, and merge-don't-overwrite means a dev
  document still carrying `sizes` keys ignores them harmlessly.
- Untouched: membership, order, names, `devices`, room nominations, the schema write-gate, and the
  merge-only mutator discipline. New mutators follow it exactly.

Built-in default spans per kind are today's `TileSpan.default(for:on:)` values (lights 1×1,
climate 2×1, cameras 2×2, …), so an unconfigured document renders exactly today's proportions.

## Core (HavenCore) — the policy layer

- **`SubsectionKind`** — `enum SubsectionKind: String, CaseIterable, Sendable`, raw values as in
  the schema. Owns `displayName` ("Scenes & more" for `.other`), `defaultSpan(on: HavenSurface)`
  (relocated from `TileSpan.default`), and the bucketing rule `SubsectionKind.of(_ primaryEntityId:)`
  — `RoomDetailView.grouped`'s switch on `Domain`, moved verbatim with its comments. Exhaustive
  with no `default`, so a new `Domain` case fails to compile here rather than silently bucketing.
  Composites bucket by their primary, exactly as today: a shade group sits with the shades.
- **`RoomSubsection`** — value type: `kind`, `refs: [DeviceRef]`, `span: TileSpan`,
  `mode: SubsectionMode`. What a container renders, fully decided.
- **`SubsectionMode`** — `enum SubsectionMode: String, Sendable { case scroll, wrap }`.
- **`Subsections.resolve(room:surface:document:) -> [RoomSubsection]`** — the one function views
  call. Consumes `room.refs(for: surface)`, so existing membership, curation tiers, and per-room
  order keep working untouched; buckets that already-filtered, already-ordered list; drops empty
  kinds; reads span and mode with their fallback chains; returns in fixed kind order. Pure function
  of its inputs, same shape as `RegistryResolver` and `CompositeState`.
- **`DashboardDocument`** accessors `subsectionSpan(_:)`, `subsectionMode(_:)`, `displayMode` and
  mutators `settingSubsectionSpan`, `settingSubsectionMode`, `settingDisplayMode`.
- **`HomeStore.subsections(_ room:, on:)`** — a thin forwarding join over the resolver, like
  `device(_:)`, and for the same reason: a view reading it must register an observation dependency
  on `config.document` through the store.

## Rendering — the app layer

- **`SubsectionView(subsection:density:)`** — header plus body.
  - Header: kind display name; the matching rollup when one exists (collapsing `rollupRow`'s
    long-flagged duplication between `RoomSectionView` and `RoomDetailView` into one place); in
    configure mode, the tap target for the subsection's settings.
  - Body, `mode == .scroll`: horizontal `ScrollView` over an `HStack`. Every tile gets an explicit
    width — span columns × the same 4-column cell width the grid derives — so a tile is
    pixel-identical in both modes; the toggle changes arrangement, never proportions. Not lazy,
    same room-scale argument `RoomGrid` documents.
  - Body, `mode == .wrap`: the existing `RoomGrid`, unchanged; uniform spans make packing trivial.
- **`DeviceTileView`** takes its span as a parameter from the container instead of reading
  `store.span(of:)`. The per-tile size-variant mappings (`ClimateTileSize(span:)` etc.) keep
  working: a 4×2 climate subsection renders every climate tile in its large variant. `TileSpanKey`
  stays, for `RoomGrid`.
- **Both surfaces** become: heading (name + environment chips, unchanged) → `ForEach` over resolved
  subsections → add-tile affordance. Floor uses `density: .compact`; exact styling is
  implementation's, the components are identical.
- **Drag-to-rearrange: reuse, not rebuild.** In configure mode every subsection renders in wrap
  mode regardless of its configured display (decision 8), so reordering always happens on
  `RoomGrid` and the existing machinery — `RearrangeableTile`, `TileDragState`, the packing-driven
  drop targets — is reused unchanged. No drag gesture is ever asked to work inside a horizontal
  scroll row.

  The per-subsection constraint is structural rather than enforced: each `SubsectionView` owns its
  own `TileDragState` (as `RoomSectionView` owns one per room today — "a drag is a fact about the
  room" becomes "a drag is a fact about the subsection"), so a lifted tile has no representation in
  any other container and cross-subsection drops cannot be expressed at all. Cross-subsection
  position is meaningless anyway: a device's subsection is a fact about its domain, not a choice.

  The mode flip on entering configure mode is a visible layout change for scroll-mode subsections
  (a row becomes a small grid). That is accepted, and consistent with configure mode already
  looking deliberately different — placeholders appear, tiles go inert, headers become tap
  targets.
- **Configuration UI:** the tile sheet loses its size picker (name, membership, state style, role
  bindings stay). A new subsection sheet — header tap in configure mode — holds size (constrained
  to the per-domain option lists `TileSizePicker` already defines, now per kind) and mode
  ("Household default" / Scroll / Wrap). The global default mode is one row in the dashboard's
  existing overflow menu. All writes go through `HavenConfig.update`.

## Testing

- **Core** (the 8-second suite): bucketing per domain including composites-by-primary; empty-kind
  dropping; fixed output order; mode fallback chain (override → global → scroll); span fallback per
  kind; per-room `order` still governing sequence within a subsection. Every new test watched to
  fail before it passes — house rule, three prior incidents.
- **App:** `ObservationTests` cases for the new read path — `subsections(_:on:)` must observe both
  the document and `states`. The tile sheet's write-back tests lose their size cases and gain
  subsection-sheet equivalents.
- **Visual:** `TileGallery` gains a subsection fixtures page — each kind, both modes, both
  densities. Gestures and scroll behaviour still need hands on a device; the gallery covers looks,
  not feel.

## Out of scope, explicitly

- Per-household subsection ordering (deferred; lands later as `display.order`).
- Any change to tile renderers' internals, the trust model, the connection layer, or curation.
- Per-entity size overrides within a subsection — rejected, not deferred.
