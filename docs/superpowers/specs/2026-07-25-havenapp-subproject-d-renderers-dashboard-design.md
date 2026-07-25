# HavenApp Sub-project D — Renderer Catalog & Dashboard UX (Design)

> **Status:** Design approved via visual brainstorm (2026-07-25), pending written-spec review.
> **Scope:** The native SwiftUI dashboard experience — the section/room + device data model, the renderer catalog (compact tiles + long-press control modals), the visual language, room detail, and the per-domain command layer. Builds on the validated foundation spike and the product-definition spec.
> **Predecessors:** `docs/superpowers/specs/2026-07-25-havenapp-product-definition-design.md` (product def), `docs/superpowers/plans/2026-07-25-havenapp-foundation-spike.md` (shipped spike: OAuth → NWConnection WebSocket → registry → live Light tile). Mockups persisted under `.superpowers/brainstorm/`.

---

## 1. Overview & what changes from the product spec

Sub-project D turns the proven plumbing into the product: a native, information-dense, controllable dashboard organized by floor → room, with a per-domain renderer for every common device and a consistent long-press control surface.

**Two amendments to the product-definition spec, decided during this brainstorm:**

1. **Source of truth = Home Assistant core primitives, not dashboard import.** Structure derives from HA's floor/area/device/entity registry (which the spike already resolves). The Lovelace "import from dashboard" onboarding path is **dropped**. Future bidirectionality (writing area/floor assignments back to HA) is noted and **deferred**. *(Supersedes product-def §11 option A; product-def §11 should be updated to registry-first.)*
2. **Sections are an abstraction with specialization kinds.** "Room" is the first (and only, in D) kind. The model is abstracted so other section kinds can be added later without re-architecting.

## 2. Design principles specific to D

- **State is carried by icon + color, never redundant text.** No "On"/"Off"/"Locked"/"Scene" labels — the glow/tint/icon convey it. Secondary text is reserved for *meaningful values* (a sensor reading, a climate setpoint).
- **One consistent control vocabulary.** Primary on/off always lives in the modal **header**. Discrete choices (climate mode, fan speed) always use the **segmented control**. Continuous values use a slider or dial. Levels (brightness, cover position) show as a **vertical level bar** on the tile.
- **Calm density.** Grouping without containers; muted off-states; color only where it means something; "unavailable" is a distinct *calm* state, not an alarm.
- **Composable detail.** A control modal is a header + a stack of facet **cards**; composite devices simply stack more cards.

## 3. Data model

### 3.1 Structure (registry-derived)
```
Home
 └─ Floor { id, name, level, sortIndex }
     └─ Section { id, name, icon, kind }              // abstract; kind is a specialization
         └─ (kind == .room) RoomSection {
              areaId,
              headerSensors: [UpliftedSensor],        // temp, humidity, … shown in the heading
              rollups: [Rollup],                       // lights, covers, … (extensible)
              devices: [DeviceRef]                     // the tiles
            }
```
- **Floors/Sections/devices come from the HA registry.** Floor ← floor registry (`level` → `sortIndex`). Room(Section) ← area registry. Device membership ← entity's effective area (`entity.area_id ?? device.area_id`), already implemented in `RegistryResolver`.
- **`Section` is a protocol/enum with associated specialization data.** Only `.room` exists in D. A section carries generic fields (id, name, icon) + kind-specific payload (`RoomSection`).

### 3.2 Uplifted sensors (room heading)
- `UpliftedSensor { role: .temperature | .humidity | …, entityId }`.
- Default source is the **area registry's designated entities** (`temperature_entity_id`, `humidity_entity_id`). Rendered in the room heading as **icon + value chips** (no labels, no blocks). Extensible to more roles later; user override is a config-mode concern (deferred).

### 3.3 Roll-ups (room-level aggregate status + action)
- `Rollup { kind, matchingEntityIds, activeCount, bulkAction }`. D ships **Lights** ("N on" → all off) and **Covers** ("N open" → close all). The list is data-driven so more domains slot in later.
- Roll-up **actions are bulk `call_service`** over the matching entities (e.g. `light.turn_off` for the room's lights).

### 3.4 Device model (entity vs. composite)
```
DeviceRef =
   | .entity(entityId)                                  // a single HA entity  (all D renders)
   | .composite(type: CompositeType, inputs: [Role: entityId])   // Haven template (abstraction only in D)
```
- A **composite** is a Haven-defined template declaring required/optional **input roles**, each bound to an HA entity, rendered as one widget (e.g. a `Climate` composite with `temperatureSource` + `humiditySource`; a smart-switch-with-power with a `switch` control + a `power` sensor).
- **In D: the composite abstraction exists in the data model, but only `.entity` DeviceRefs are produced and rendered.** Composite instantiation/binding needs config UI (a later sub-project). Modeling it now avoids re-architecting the renderer/modal layer, which is already composable (§6).

## 4. Renderer catalog (D first iteration)

Build the **framework + these renderers**; defer **Media Player** and **Camera** to D.2.

| Renderer | HA domain(s) | Tile (compact) | Tap action | Control modal |
|---|---|---|---|---|
| **Light** | `light` | icon (amber glow when on), name, vertical level bar = brightness | toggle | header on/off; brightness slider; color-temp bar (RGB color = later) |
| **Switch/Outlet** | `switch`, `input_boolean` | icon, name, on-glow | toggle | header on/off (+ sensor facet if composite, later) |
| **Cover/Shade** | `cover` | icon (blue when open), name, level bar = position | open ↔ close (toggle) | header state; position slider; open / stop / close buttons |
| **Lock** | `lock` | icon (green locked / amber unlocked), name | lock ↔ unlock | header lock/unlock; state + last-changed |
| **Climate/Thermostat** | `climate` | icon, big temp, mode subtext | open modal | header on/off; temperature dial; **Mode** segmented (Heat/Cool/Auto); **Fan** segmented |
| **Scene/Script/Button** | `scene`, `script`, `button` | icon (purple), name | run | run + last-run info (minimal) |
| **Sensor** | `sensor` | icon, name, value | open modal | **history-first**: current value + smoothed chart + range (Day/Week/Month/3M/Year) + min/avg/max |
| **Binary Sensor** | `binary_sensor` | icon + device_class color, name | open modal | current state + recent changes (deep timeline = later) |
| **Generic fallback** | any other | icon, name, state string | more-info | more-info: state + attributes list |

Notes:
- **Media Player** and **Camera** are explicitly out of D (→ D.2).
- **Sensor history** is part of D because it is core to the sensor renderer. It queries HA's `history/history_during_period` (recent) and `recorder/statistics_during_period` (longer ranges), switching source by selected range. Curves are **smoothed** (monotone/Catmull-Rom). *(This is the one deep-history piece that lands in D; broader energy/multi-series viz remains later.)*

## 5. Visual language — "Light Glass · Vibrant" (theme-aware)

- **Material:** frosted Liquid-Glass tiles (translucent, blurred, subtle inset highlight) on a softly-tinted field. **Theme-aware** — light-primary, adapts to dark automatically via the system theme.
- **Active = domain-color glow.** On/active devices fill with a soft domain-color gradient and glow; off/inactive are muted glass; **unavailable** is a distinct calm/greyed state (not red).
- **Domain colors:** light = amber, cover = blue, lock = green (unlocked = amber/red), climate = warm red/orange, scene = purple, sensor = neutral/blue, alerts/critical = red.
- **Icons:** curated **SF Symbols** mapped by `domain` + `device_class` (cohesive, native, weight/gradient-aware, no bundled asset). A specific-`mdi:` → MDI-font path is a later fidelity option. *(Nit to honor in the mapping: temperature uses the classic bulb-thermometer symbol, e.g. `thermometer.medium`, not a round dial.)*
- **Tiles:** 4-column grid, unlimited height, sizes **1×1 / 2×1 / 2×2**. Content = icon (top-left), name, optional value line (sensor reading / climate temp only) + optional **vertical level bar** on the right edge (brightness / position). Non-dimmable "on" shows glow with no bar.

## 6. Interaction & the control modal

- **Tap = primary action** (toggle / run / open↔close), optimistic with rollback (as in the spike).
- **Long-press = control modal** — a large centered Liquid-Glass panel that morphs from the tile.

**Modal structure (universal):**
```
Header:  icon · name · state subtitle · PRIMARY on/off toggle · close
Body:    a vertical stack of facet CARDS
           • secondary-control card(s): primary continuous control (slider/dial) +
             segmented controls for discrete choices
           • sensor/history card(s): value + smoothed chart + range selector + min/avg/max
```
- **Primary on/off is always in the header** — for single entities and composites alike.
- **Single-facet devices** (light, switch, climate…): on/off in header, the primary control fills the modal, **no card chrome**.
- **Multi-facet composites** (later): each facet is a titled card stacked in the modal; the primary on/off still lives in the header.
- **History appears only on sensor facets**, prominent, with the range selector. Actuators have no history line.

## 7. Room detail

Tapping a room heading opens the full room:
- **Nav:** back + room name; **temp/humidity as icon+value chips** in the header (seamless, no blocks/labels).
- **Grouped by domain** — Climate, Lights, Shades/Covers, Scenes & more, Sensors. Each group is a **plain heading** (no container/border) with an optional right-aligned **roll-up action** in the header ("N on · All off", "N open · Close all").
- **Same tiles and interactions** as the dashboard; this view organizes one room by type and gives it room to breathe.
- Roll-ups live as **per-group header actions** (no separate top roll-up bar in room detail).

The **floor-tab room section** (overview) uses the same tiles with the room name + env chips + roll-up in its heading; tapping the heading → room detail.

## 8. Architecture (SwiftUI / HavenCore)

- **Renderer dispatch:** a factory mapping an entity's `domain` (+ `device_class`) → its tile view and modal view. A single `DeviceTileView` / `DeviceModalView` entry point resolves the concrete renderer. Unknown domains → Generic.
- **Typed per-domain state:** lightweight value types (`LightState`, `CoverState`, `ClimateState`, `LockState`, `SensorState`, …) computed from `EntityState.attributes`, so views read typed fields instead of raw `JSONValue`. Lives in `HavenCore`.
- **Command layer:** extend `HomeConnection` with per-domain `call_service` methods — light (turn on/off, brightness, color-temp), switch (toggle), cover (open/close/stop/set position), lock (lock/unlock), climate (mode, target temp, fan), scene/script (activate). (Command transport is HA-standard; may be shared with Sub-project C.)
- **Structure/section model:** `Section`/`RoomSection`/`DeviceRef` as in §3; a mapper builds them from the resolved registry.
- **Roll-ups:** pure functions computing active counts + producing bulk `call_service` actions from a room's entities.
- **Icon mapping:** `IconMap` — `domain`+`device_class` → SF Symbol name.
- **History:** a `HistoryService` querying `history/history_during_period` and `recorder/statistics_during_period`, range-aware; feeds Swift Charts with smoothed interpolation.
- **Design system:** `DesignSystem` module — glass tile container, level bar, segmented control, chips, control-modal scaffold, domain color/icon tokens.

Design each of the above as a focused unit with a clear interface (a renderer knows only its typed state + command closures; the dispatch knows only domain→renderer; the modal scaffold knows only header + [cards]).

## 9. Scope boundary

**In scope (D):**
- Registry-derived Floor → Room(Section) → device structure; Section/RoomSection/DeviceRef data model (composite = abstraction only).
- Uplifted room temp/humidity (from area registry) as header chips; Lights + Covers roll-ups (extensible).
- Visual language (Light-Glass-Vibrant, theme-aware, SF-Symbol icon map, level bars, state-by-color).
- Renderer catalog: Light, Switch/Outlet, Cover, Lock, Climate, Scene/Script, Sensor, Binary Sensor, Generic (framework + these 9).
- Tap actions + long-press control modal (header + facet-cards pattern) with the per-domain modal contents in §4.
- Sensor history (value + smoothed chart + Day/Week/Month/3M/Year range + stats) via HA history/statistics.
- Room detail (grouped-by-domain, per-group roll-up actions).
- Per-domain command layer.

**Deferred:**
- **Media Player** and **Camera** renderers (→ D.2).
- Composite device instantiation/binding + config mode (→ config sub-project). RGB light color, deep binary-sensor timelines, broader energy/multi-series visualization.
- Bidirectional writes of area/floor assignments back to HA.
- Additional section kinds beyond Room.

## 10. Success criteria

- Every entity in a room renders via its domain renderer (or Generic), with state read at a glance from icon + color; no redundant on/off text.
- Tap toggles/runs optimistically; long-press opens the correct control modal with working controls (brightness, temp/mode/fan, position, lock).
- A room heading shows uplifted temp/humidity as chips and accurate Lights/Covers roll-ups whose bulk actions work.
- A sensor's modal shows a smoothed history chart with a working range selector pulling real HA data.
- Room detail groups devices by domain with no container chrome and per-group roll-up actions.
- The whole surface reads as one cohesive Light-Glass system in both light and dark.

## 11. Open questions / follow-ups

- **Icon nit:** temperature → classic bulb-thermometer symbol (capture in `IconMap`).
- **Sensor-history depth in D:** confirmed in-scope but implemented as the sensor renderer's history (single-series, range-switched); broader energy viz stays later.
- **Product-def spec §11** should be updated to registry-first (dashboard import dropped) for consistency.
- **Command layer ownership:** may be built here or shared with Sub-project C — resolve at plan time.
