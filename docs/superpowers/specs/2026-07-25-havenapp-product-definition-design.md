# HavenApp — Product Definition & Dashboard Paradigm (Sub-project A)

> **Status:** Design approved (2026-07-25), pending written-spec review.
> **Scope:** This is the product-definition spec for HavenApp — the vision, information architecture, dashboard paradigm, interaction model, and v1 scope boundary. It is Sub-project **A** of a larger program (see §3). Technical/implementation specs for the other sub-projects (integration, connection engine, renderers, iOS-18/26 surfaces, notifications) are separate documents that follow from this one.
> **Companion research:** `docs/domika-analysis-and-ios-plan.md` (reverse-engineering of Domika + protocol) and the research appendix in §16.

---

## 1. Vision

HavenApp is a **fast, native iOS 26 control surface for Home Assistant** that projects a home the way people actually think about it — **floors and rooms** — and beats the incumbent apps (the Home Assistant companion app, Apple Home, Lutron) on the three things they all get wrong: **speed, information density, and real history**.

Home Assistant remains the brain (data, devices, automations); HavenApp is a best-in-class **face** for controlling and monitoring the home day to day. It is not a Home Assistant configuration/automation-authoring tool.

**The opportunity (from research, §16):** every incumbent fails in the same places — HA's own app is a WebView that can take ~30s to load; Apple Home has *no* historical graphs; Lutron has no history and makes you open a slider just to toggle a light; SmartThings takes ~1 minute to load a busy room. Nobody delivers *fast + information-dense + native + real history*. That is the seam HavenApp exploits.

## 2. Target user, goals, non-goals

**Target user (v1):** an existing Home Assistant owner whose entities are largely organized into areas, who finds the HA app / HomeKit / Lutron clunky, and who wants a premium, glanceable daily-driver for controlling and monitoring their home.

**Goals:**
- Open-to-interactive in well under a second; controls respond instantly (optimistic UI).
- A calm, information-dense view of the whole home, organized by floor → room.
- Native controls for every common device type, with a rich control modal per device.
- A genuine "needs your attention" surface (safety, security, battery, offline).
- A highly functional configuration capability that, once used, the user never needs to revisit.
- Privacy/local-first: no HavenApp-operated cloud for data.

**Non-goals (v1):** editing HA automations/scenes/integrations; device onboarding/pairing; being a general HA dashboard editor; multi-user/household roles; Android.

## 3. Program context — where Sub-project A fits

HavenApp is decomposed into independently-buildable sub-projects. This spec defines **A** and the product contract the others implement against.

| # | Sub-project | Summary | Depends on |
|---|---|---|---|
| **A** | **Product definition & dashboard paradigm** (this doc) | Vision, IA, dashboard model, interaction model, v1 scope | — |
| B | `haven-hacs` integration | Custom HA integration (Python): efficient subscriptions, entity commands, config blob storage, push registration | A |
| C | iOS connection engine | OAuth against HA, WebSocket transport (actor), local/Nabu Casa URL selection, live state, optimistic control | A, B |
| D | Renderer catalog & dashboard UI | SwiftUI tile renderers + the dashboard canvas + control modals (registry-derived rooms; config mode is a later sub-project) | A, C |
| E | iOS-26 surfaces | Widgets, Control Center / Lock Screen controls, Live Activities, Watch, App Intents/Siri | C, D |
| F | Notifications / critical alerts | Push pipeline within the no-cloud constraint (leverage HA/Nabu Casa push) | B, C |

Each sub-project gets its own spec → plan → build cycle.

## 4. Design principles

1. **Native, never a WebView.** WebSocket → native SwiftUI render. Sub-second responsiveness is the core promise.
2. **Calm density.** Show a lot without shouting: counts over lists ("2 lights on"), climate as quiet subtext, color *only when it means something*. Management-by-exception — normal state stays peripheral; only what needs the user comes to the center.
3. **Optimistic control.** Every action responds in <100ms and reconciles when the socket confirms; roll back on failure.
4. **The registry is the source of truth for structure.** Floors/rooms/devices derive from HA's floor/area/device/entity registry; user configuration layers on top as overrides.
5. **Progressive disclosure.** Overview → room → device. A tile answers "what's on / what's the temp / anything wrong?"; long-press opens full control.
6. **Privacy / local-first.** No HavenApp cloud for data. Local network primary; Nabu Casa only to reach home when away. Config lives in the user's own HA.
7. **Explicit modes.** Normal mode is for *using* the home (tiles are inert to rearrangement); configuration is a deliberate, separate mode.

## 5. Information architecture

A single `.sidebarAdaptable` `TabView` — a floating Liquid-Glass tab bar on iPhone, a sidebar on iPad — from one declaration.

- **① Home (overview tab), default landing:** whole-home status at a glance — the **Attention strip** (visible only when something needs the user), a compact **weather/now** header (WeatherKit current conditions; light touch in v1), **Favorites** (pinned tiles/scenes), and quick whole-home actions (e.g. "all lights off," arm).
- **② … Floor tabs:** one tab (`TabSection`) per floor, sorted by the registry `level` (basement negatives handled). Each floor screen is a vertical scroll of **room sections**; each section is a heading (name + optional icon) plus a **4-column tile grid**. Tapping a section heading opens **Room detail**.
- **No search tab.** Once configured, the floors/rooms are the navigation.

**Degenerate cases:**
- **No floors defined:** collapse to a single implicit floor — Home shows room sections directly, no floor tabs.
- **One floor:** skip the redundant floor tab.
- **Unassigned entities:** an "Unassigned/Other" bucket so nothing is invisible.

**iPad:** the tab bar becomes a sidebar; the 4-column room grid stays 4 columns (cells get roomier) rather than stretching.

## 6. The dashboard model

**Hierarchy (mirrors HA, stored as Haven's own editable config):**
```
Home → Floor { name, level, icon, sections[] }
       Section (room) { name, icon, tiles[] }        // "section" == a room or a custom group
       Tile { entityRef(s), size, label?, icon?, options } // one entity (or small group) rendered natively
```

**Grid:** each section is a **4-column-wide grid, unlimited height**. Tiles occupy **1×1, 2×1, or 2×2** cells. The grid preserves spatial memory — tile positions are stable across screen sizes (columns stay fixed; cells resize). Default sizes are per-domain (e.g. a light = 1×1; a thermostat or camera = 2×2) and are user-overridable in config mode.

**Room detail** = the room's full tile set grouped by domain (all lights, all covers…), a room climate readout up top (using the area's designated `temperature_entity_id` / `humidity_entity_id`), and room-scoped scenes.

## 7. Renderer catalog (v1)

Each tile renders via a **native per-domain renderer**. v1 catalog:

| Renderer | HA domain(s) | Tile shows | Tap action | Long-press modal |
|---|---|---|---|---|
| Light | `light` | on/off, brightness tint | toggle | brightness, color, color-temp, effects |
| Switch/Outlet | `switch`, `input_boolean` | on/off | toggle | on/off + state/history |
| Cover/Shade | `cover` | position/state | open/close (or stop) | position slider, tilt |
| Lock | `lock` | locked/unlocked/jammed | lock/unlock | lock control + state |
| Climate | `climate` | current temp, mode | open modal | temperature dial, HVAC mode, fan mode, preset, humidity |
| Media Player | `media_player` | state, now-playing | play/pause (or open) | transport, volume, source |
| Scene/Script | `scene`, `script`, `button` | name/icon | run | (confirmation / run) |
| Sensor | `sensor` | value + unit, sparkline | open modal | value + glance history |
| Binary Sensor | `binary_sensor` | status (color when active) | open modal | status + device_class detail |
| Camera | `camera` | snapshot/live | open modal | live view (HLS) |
| **Generic fallback** | any other | state string | more-info modal | raw state/attributes |

The **Generic fallback** guarantees nothing is unrenderable — unknown domains still show state and a more-info modal.

## 8. Interaction model

**Normal mode (default). Tiles are inert to arrangement — no dragging, no jiggle.**
- **Tap** = the primary action for the domain (toggle light, run scene, open/close cover). Optimistic and instant.
- **Long-press** = **open the tile as a large centered modal** (Liquid Glass, morphing out of the tile) exposing the full native controls for that entity. Examples: long-press a 1×1 light → centered modal with a brightness slider; long-press a thermostat → modal with the full temperature dial, HVAC mode, fan mode, etc. Long-press is always an *action* — never a trigger to rearrange.
- Read-only tiles (e.g. sensors) open the same modal on **tap** (nothing to toggle).

**Configuration mode (explicit — the user deliberately enters it, e.g. via an Edit control):**
- Tiles become **draggable/rearrangeable** on the 4-column grid, and **resizable** (1×1 / 2×1 / 2×2).
- **Tap a tile → edit its configuration** (size, label, icon, default-action override, shown attributes, sparkline on/off).
- Each **section** can be **renamed** and given an **optional icon**.
- A **dotted "+" tile** at the end of each section adds a new device (entity browser grouped by domain/area).
- Sections and floor tabs can be reordered; rooms/floors/entities can be hidden.

## 9. The Attention construct

A home-wide, always-curated list of things that need a human — the feature that visibly beats every incumbent.

**Surfaces:** a **collapsing strip at the top of Home** (+ a per-floor/room badge), expanding to a full **Attention view**.

**What it catches (v1), all derived from HA semantics (device_class/state), not entity names:**
- **Safety** (`binary_sensor` device_class): smoke, carbon_monoxide, gas, moisture/leak, heat, safety.
- **Security/state:** doors/windows/garage left open; alarm triggered/armed state.
- **Health:** device offline/`unavailable`; low battery (default threshold ≤20%).

**State model (the key insight):** `unhandled` → `acknowledged` (seen, condition still active) → `resolved` (auto-clears when the condition clears). Acknowledge ≠ fixed. Resolution emits a quiet **recovery** note ("Leak sensor back to normal").

**Calm behavior:**
- **Hide-when-empty** everywhere; positive empty state only where reassuring ("All doors closed").
- Severity encoded as **color + icon + text** (never color alone); sorted worst-first; grouped by room/floor.
- Filter out `unavailable`/`unknown` before evaluating thresholds.
- **Severity tiers** are defined now and map to iOS interruption levels for the future push layer (Sub-project F): safety → `critical`, warnings (open/offline/low-battery) → `time-sensitive`, info → `passive`. In v1 this drives the **in-app** surface only.

**Configurable (see §10):** which sensors count as critical (default from device_class, user-overridable), battery threshold, per-device "include in summary" opt-out, snooze.

## 10. Configuration capability

A first-class pillar. Principle: **registry auto-generation gets you to a great default in seconds; configuration makes it exactly yours; then you never think about it again.** All configuration happens in the explicit **configuration mode** (§8).

**Capabilities:**
- **Structure:** rename floors/rooms, custom icons, hide rooms/floors/entities, create custom sections beyond the registry, and **reassign an entity to a different room** as a local override (HA's own area data is never modified).
- **Tiles:** add/remove (via the "+" tile / entity browser), drag to reposition, resize (1×1/2×1/2×2), per-tile label, icon, default-action override, shown attribute(s), sparkline on/off.
- **Favorites:** pin tiles/scenes to the Home overview.
- **Attention tuning:** override critical-sensor classification, battery threshold, per-device "include in summary" opt-out, snooze.

**Persistence & sync (privacy-first, no Haven cloud):** Haven's config is its own state and syncs across the user's devices by being stored **in the user's own Home Assistant** via the `haven-hacs` integration (a stored key/blob, the mechanism Domika uses for its dashboard blob). A local cache provides instant load; HA is the sync point. Nothing touches a Haven-operated server. (Contract for Sub-project B.)

**HA is the single source of truth for configuration — not the device, not a cloud.** The local cache is a read-through cache for startup latency, never an authority: on conflict, HA's stored config wins, and a device that edited offline reconciles against it rather than overwriting blindly.

**Multi-user households (added 2026-07-25).** Because config lives in HA rather than on a device, several people in the same household can see the *same* configured view from their own phones — this is a first-class goal, not a side effect. It requires decisions deferred to Sub-project B:
- **Shared vs per-user scope.** The default should be one **shared household configuration** (everyone sees the same rooms/tiles, which is what makes a home dashboard feel coherent). Genuinely personal state — favorites, which rooms you pinned, per-device widget choices — likely wants a **per-user overlay** keyed by the HA user id, layered over the shared base.
- **Concurrent edits.** Two people editing the dashboard at once needs at minimum last-write-wins with a version/etag so a stale client can detect it was superseded, rather than silently clobbering.
- **Permissions.** Whether every HA user may edit the shared config, or only admins, follows HA's own admin flag.

## 11. Onboarding (registry-first)

> **Amended 2026-07-25** (during Sub-project D design): HavenApp is **registry-first** — HA's floor/area/device/entity registry *is* the structure of truth. The earlier "migrate an existing Lovelace dashboard" path is **dropped from v1** (deferred as a possible future import). See `docs/superpowers/specs/2026-07-25-havenapp-subproject-d-renderers-dashboard-design.md` §1.

First-run should reach a ready-to-use app in seconds, not present an empty canvas.

**Flow:**
1. **Connect HA** — enter/discover the local HA URL, authenticate via OAuth (Sub-project C).
2. **Auto-generate from HA's core primitives** — build floors → rooms (sections) → device tiles directly from the HA floor/area/device/entity registry (applying the entity→area→floor resolution rule, §16). HA's registry already models floors, rooms (areas), device→area associations, and designated room temperature/humidity entities, so this yields a correct, complete structure with no manual setup.
   - **Start blank** remains available as an escape hatch for users who want to build up manually.
3. **Land in a working app**, optionally refine in configuration mode (later sub-project).

**Source of truth is HA, read-only in v1.** Haven derives structure from the registry and never writes area/floor assignments back to HA in v1. **Future bidirectionality** (editing structure in Haven and pushing it to HA) is noted and deferred. Lovelace dashboard *import* is likewise a deferred future option, not a v1 path.

## 12. Settings

A general settings flow, separate from dashboard configuration:
- **Connection:** local Home Assistant URL; **Nabu Casa remote access** (remote reachability when off-LAN); connection status.
- **Home management:** the active home (multi-home is a later sub-project; v1 supports at least one home cleanly).
- **Preferences:** units (respecting HA's unit system by default), theme/appearance, notifications (placeholder in v1; wired in Sub-project F).
- **About / Help / Legal**, and **sign out**.

## 13. Data & sync model (summary)

- **Structure source:** HA registries (floor/area/device/entity) over the WebSocket, resolving each entity's effective area via `entity.area_id ?? device.area_id`, then `area.floor_id`.
- **Live state:** WebSocket subscription (efficient, batched via `haven-hacs`; Sub-project C/B). Optimistic writes for control.
- **Config:** Haven's own model, stored in the user's HA via `haven-hacs`, cached locally.
- **Remote access:** local URL when on-LAN; Nabu Casa external URL when away (URL selection in Sub-project C).
- **Weather:** WeatherKit (attribution displayed wherever weather shows).

## 14. v1 scope boundary

**In scope (v1):**
- Connect to HA (OAuth) + Nabu Casa remote; local-first.
- Onboarding: auto-generate the floors/rooms/tiles structure from the HA registry (or start blank).
- Home overview tab (Attention strip + light weather header + Favorites + whole-home actions) + floor tabs → room sections → 4-column tile grid.
- Native renderer catalog (§7).
- Normal-mode interaction: tap action + long-press control modal; configuration mode: drag/resize/label/icon/add/remove, section rename+icon, "+" tile.
- Attention construct (safety + security + battery + offline; 3-state; in-app surface).
- Glance sparklines on sensor tiles.
- Config persisted in the user's HA via `haven-hacs` + local cache.
- General settings flow.

**Deferred to v2+:**
- Deep, scrubable history & energy visualizations (Health-style D/W/M/6M/Y).
- Full environmental experience ("indoor vs outdoor," "should I open the windows?" dew-point verdict).
- Push notifications / Critical Alerts wiring (Sub-project F).
- Widgets / Control Center / Lock Screen controls / Live Activities / Watch (Sub-project E).
- Lovelace dashboard import; bidirectional writes of structure back to HA; multiple dashboards/views per home; multi-home management UI; iPadOS-specific refinements beyond adaptive layout.

## 15. Success criteria

- **Performance:** cold launch to interactive home view < 1s on a warm connection; control actions reflect optimistically < 100ms.
- **Zero-setup value:** a new user with an organized HA reaches a usable, correct floors/rooms view within the onboarding flow without manual tile-building.
- **Calm correctness:** in a normal home, the Attention surface is empty/collapsed; when a real event occurs (leak, door open, low battery, offline), it appears promptly with correct severity and clears on recovery.
- **Configurability:** a user can fully rearrange a room (add/remove/resize/reposition tiles, rename section) without documentation, and the result persists across devices.
- **Density:** a room section conveys lights-on count, climate, and any alerts at a glance without drilling in.

## 16. Research appendix (grounding & key facts)

Full cited research was produced during design (four streams: iOS 26 design; HA dashboards/data model; competitor UX; data-viz/alerts). Load-bearing facts used above:

- **HA home structure:** Floor (`level`, sortable, negatives allowed) → Area/room (`floor_id`, plus `temperature_entity_id`/`humidity_entity_id`) → Device (`area_id`) → Entity (`area_id`, `device_id`). **Effective area = `entity.area_id ?? device.area_id`; floor = that area's `floor_id`.** Registries via WebSocket: `config/floor_registry/list`, `config/area_registry/list`, `config/device_registry/list`, `config/entity_registry/list` (+ `..._for_display`). HA now ships an auto-generated Areas dashboard from exactly this model. Sources: home-assistant.io/docs/organizing/, developers.home-assistant.io/docs/api/websocket/.
- **iOS 26 (Liquid Glass):** `.sidebarAdaptable` `TabView` + `TabSection` (floating tab bar on iPhone / sidebar on iPad from one source); `glassEffect`, `GlassEffectContainer`, `.tabBarMinimizeBehavior`, `.tabViewBottomAccessory`; zoom navigation via `matchedTransitionSource` + `.navigationTransition(.zoom)`; Swift Charts (`chartXSelection`, scrollable domains) for history; App Intents unify widget/Control Center/Siri; WeatherKit (no AQI — needs AirNow/Open-Meteo later; mandatory Apple Weather attribution). Sources: developer.apple.com Liquid Glass / WWDC25 sessions 219/278/323.
- **Room-at-a-glance:** counts over lists ("2 lights on"), climate as secondary text, alert icons only when active, color = meaning, quiet by default (Mushroom/Bubble/Tile/Area cards; matt8707 config).
- **Alerts:** device_class-driven, 3-state (unhandled→acknowledged→resolved), hide-when-empty, severity → iOS interruption levels; HA's Maintenance dashboard (2026.5) precedent for battery/offline grouping.
- **Competitive gap:** native-over-WebSocket beats every incumbent on speed; Apple Home has no charts; Lutron no history + too many taps; SmartThings slow + silent sensor failures. Optimistic UI + real history + a real attention surface are the differentiators.
- **Interaction:** tap = obvious action; rich control behind a deliberate gesture (here: long-press → centered modal); progressive disclosure overview→room→device.

## 17. Open questions / dependencies

- **B (haven-hacs):** exact stored-config key/schema and whether v1 can ship against stock HA (registry + standard subscriptions) while the integration matures — decide in Sub-project B/C specs. (v1 product value does not strictly require the custom integration except for the most efficient subscriptions and config sync; a fallback to stock HA `store`/local-only is worth evaluating.)
- **C (connection):** precise Nabu Casa remote URL acquisition + local/remote selection and failover; OAuth client identity (our own `client_id` URL + `havenapp://` redirect scheme).
- **Weather header in v1:** confirmed light-touch (current conditions only); full environmental experience is v2.
- **Repo:** not yet a git repository — initialize before committing specs/code.
