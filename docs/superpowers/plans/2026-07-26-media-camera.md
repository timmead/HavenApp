# Media Player & Camera Renderers — Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development.

**Goal:** Build the two D.2 renderers to the approved mocks, plus the vendor hand-off
(UniFi Protect / Sonos) and the authenticated image loading both depend on.

**Approved design:** the reviewed mock — tile sizes, control layouts, hand-off behaviour and
copy are all settled. Do not redesign; implement.

**Branch:** `feat/media-camera`. **Tech:** Swift 6 (strict concurrency `complete`), SwiftUI, iOS 26, Swift Testing.

## Global Constraints

- Decision logic lives in **HavenCore as pure functions, unit-tested**. `App/` renders and
  forwards intent only. There is **no App-layer test target** — logic placed there is
  unverifiable, and that is how several bugs in this project shipped green.
- **Never contact a live Home Assistant.** Unit tests against fakes only.
- Service domains derive from the **entity-id prefix**, never a renderer enum (D spec §10a) —
  getting this wrong makes calls silently succeed and do nothing.
- **`.gridCellColumns` is inert inside `LazyVGrid`** (D spec §10a). A 4-wide tile needs its own
  grid/row with a narrower `[GridItem]`, not a span modifier.
- **No hardcoded colours** — use `App/DesignSystem/Theme.swift`. Dark mode has regressed twice.
- Accessibility: labels carry state in **text**, adjustable controls get `accessibilityValue`
  and `.accessibilityAdjustableAction` (see `AccessibilitySummary` for the established pattern).
- Verify: `cd Packages/HavenCore && swift test`, then from repo root
  `xcodegen generate && xcodebuild -project HavenApp.xcodeproj -scheme HavenApp -sdk iphoneos26.5 -configuration Debug build CODE_SIGNING_ALLOWED=NO`.
  All existing tests must keep passing. Run `xcodegen generate` after adding files under `App/`.
- Commit trailer: `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`
- Do not use `git stash`.

---

## Task 1: Authenticated image loading

Both renderers need it and the app has none. `AsyncImage` cannot attach an `Authorization`
header, so it **silently 401s and renders its placeholder** — a blank tile that looks like a
working camera with nothing to show rather than an error.

- Resolve a relative HA path (`entity_picture`, `/api/camera_proxy/<id>`) against the **current**
  base URL and attach the bearer token.
- **Take base URL and token from `TokenProvider` at request time — never capture them.** The app
  now fails over between local and remote mid-session; a captured URL points at the wrong host
  after failover.
- In-memory cache; **cancel on disappear**. Never log or persist the token, and never use it in a
  cache key.
- Put URL resolution and cache-key derivation in HavenCore as pure functions and test them
  (relative vs absolute paths, base-URL change invalidating correctly, token absent).
- A load failure must be **distinguishable from "no image"** in the API so callers can show an
  error state rather than a plausible blank.

## Task 2: Vendor hand-off + registry fields

Cross-cutting foundation for both modals.

- Decode **`platform`** and **`unique_id`** on `EntityRegistryEntry` — verified present in
  `config/entity_registry/list` against Home Assistant's source. Thread them through the resolver
  to where renderers can read them.
- Pure `VendorHandoff` type in HavenCore: given platform + unique_id, produce an ordered list of
  candidate URLs. **A ladder, never a cliff:** per-device link → plain app launch → nothing
  (button hidden). Never a dead tap.
  - `unifiprotect` → `unifi-protect://protect/devices/<id>`, then `unifi-protect://`
  - `sonos` → `sonos://`
  - **Both per-device forms are UNVERIFIED** (Ubiquiti's threads are JS-rendered; Sonos documents
    only the outbound direction). Structure so each is one string to change, and say so in the doc
    comment. Do not present them as confirmed.
- App layer tries candidates in order via `canOpenURL`/`open`, hiding the button when none opens.
- **Add both schemes to `LSApplicationQueriesSchemes` in `Info.plist`** — `canOpenURL` returns
  false for any undeclared scheme, so without this the button always believes the app is missing.
- Tests: candidate ordering per platform; unknown platform yields none; a nil `unique_id` still
  yields the plain app-launch candidate.

## Task 3: Media Player renderer

Typed `MediaPlayerState` from `EntityState` (playing/paused/idle/off/unavailable, title, artist,
artwork path, volume, muted, source list, position + `media_position_updated_at`,
`supported_features`). Commands via entity-id prefix.

**Tiles** — per the mock:
- **1×1**: centred play/pause, name beneath. No size is a pure launcher.
- **2×1**: no artwork. Title occupies the artwork's place in a fixed-height window that
  **scrolls slowly to its last line, holds, returns** — only when the text actually overflows.
  Honour **Reduce Motion** (clamp instead). Static when it fits.
- **4×2**: artwork fills the left side, prev/play/next overlaid on a scrim over its bottom;
  right column has title/album top, volume bottom. Needs its own grid row — see Global Constraints.

**Modal**: header (icon · name · state · power toggle **or** Sonos hand-off · close) → now-playing
card with artwork, title, artist and a progress bar → transport → volume → source.
- **Progress must tick locally** from `media_position_updated_at`; HA only re-reports on change, so
  a naive render freezes mid-track. Stop ticking when paused. Put the interpolation in HavenCore
  and test it.
- **Header toggle is power, never play/pause.** Where power is unsupported and the platform isn't
  Sonos, show no toggle rather than repurposing it.
- **Sonos (`platform == "sonos"`) replaces the toggle with the hand-off button** — Sonos speakers
  have no meaningful on/off. Per-integration swap, not a global change.
- Gate each transport control on its own `supported_features` bit; **omit** unsupported ones rather
  than showing them disabled.
- Source: segmented control at ≤4 options, menu beyond.

**Out of scope:** speaker grouping, media browsing, TTS targets.

## Task 4: Camera renderer

- **Tiles: 2×2 and 4×2 only.** 2×2 = still image above a caption strip with a staleness stamp
  ("12s ago"). 4×2 = full-bleed still with name over a gradient scrim, no stamp.
- Stills, not streams: refresh roughly every 10s, and **stop when the app backgrounds or the tile
  leaves the screen**. Snapshot via `/api/camera_proxy/<entity_id>` through Task 1's loader.
- **Modal**: live view via the `camera/stream` WebSocket command (HLS URL → `AVPlayer`), MJPEG
  fallback where `stream` is unsupported.
  - **A pulsing dot and nothing else** — no "LIVE" text, no clock. Honour Reduce Motion.
  - **Speaker control on the feed, bottom-right, defaulting to muted.** A camera that starts
    talking when opened is startling, and audio is what's most likely to be overheard by someone
    who didn't open the app.
  - **Events** card (not "Related"): related motion/person/doorbell binary sensors as chips.
  - **Protect hand-off** button in the header.
  - Tear the stream down on dismiss.
- Add `camera` to `EntityCuration.primaryDomains` now that a renderer exists.

**Out of scope:** PTZ, recordings, two-way audio.
