# Domika Reverse‑Engineering Analysis & HavenApp (iOS) Implementation Plan

> Static analysis of `com.devpocket.domika.android` v1.0.22 (versionCode 122), decompiled with jadx/apktool. No app execution. Purpose: build a ground‑up iOS Home Assistant client (HavenApp) that reuses Domika's proven architecture where sensible and deliberately differs where we choose.

---

## 1. What Domika actually is

Domika is a **native Home Assistant client** whose differentiator is *not* being a full HA UI. It focuses on the everyday "walk‑past controls": toggle a light, nudge the thermostat, close the garage — plus **critical safety push** (smoke/gas/leak) and **home‑screen widgets**. It deliberately does **not** do device setup, automations, or integrations.

The clever part — and the pattern you correctly identified — is a **three‑tier architecture**:

```
┌────────────────┐        HA WebSocket (/api/websocket, JSON)         ┌──────────────────────┐
│  Native app    │  ⟷  auth_required→auth→auth_ok, then:              │  User's Home          │
│  (Domika)      │       • standard HA commands (get_config, …)       │  Assistant server     │
│                │       • CUSTOM  domika/*  commands  ───────────────┼─▶  domika-hacs        │
│                │       • subscribe_events domika_critical_…         │   (custom integration │
└──────┬─────────┘                                                    │    installed via HACS)│
       │  APNs/FCM push (critical alerts)                             └──────────┬───────────┘
       │                                                                         │ triggers push
       ▼                                                                         ▼
┌────────────────┐                                                    ┌──────────────────────┐
│ Apple APNs /   │  ◀───────────  push relay  ───────────────────────│  Domika cloud         │
│ Google FCM     │                                                    │  (push backend)       │
└────────────────┘                                                    └──────────────────────┘
```

Three cooperating pieces:

1. **The native app** — the client (what we're rebuilding for iOS).
2. **`domika-hacs`** — a **custom Home Assistant integration** (`github.com/DevPocket/domika-hacs`, installed through HACS) that runs *inside the user's HA*. It registers extra WebSocket commands (`domika/…`) that act as an efficient **transport/aggregation layer** — batched subscriptions, entity metadata, critical‑sensor detection, dashboard blob storage, and push registration. This is the "comms transport tunnel."
3. **Domika cloud** (`login.domika.app` + a push backend) — used only as the **OAuth `client_id` identity** and as the **push relay** that the integration calls to fan critical events out to APNs/FCM. It is *not* a data plane; app data never flows through Domika's servers.

**Key insight for us:** the app connects **directly to the user's HA** for all data. The custom integration exists to make that connection *efficient and push‑capable* (HA's raw WebSocket firehose is chatty; `domika/resubscribe` lets the client subscribe to just the attributes it needs at two priority tiers). Everything the app renders is standard HA entity state.

### Tech stack (Android)
- **Kotlin, Jetpack Compose**, single‑Activity (`AppActivity`) + `WidgetActivity` + `VideoActivity` (camera).
- **Clean Architecture**: `core/data` (repos, DataStore, Room), `core/domain` (entities, use cases), `feature/*` (per‑screen MVVM), `di` (Hilt), `uikit` (design system), `navigation` (type‑safe nav graph).
- **Networking**: Ktor client + OkHttp engine. WebSocket to `/api/websocket`; REST for `/auth/token`, `/api/states`.
- **Wire format**: **JSON** (kotlinx.serialization). Protobuf is used **only for local persistence** (Android DataStore) and as an opaque blob embedded inside `domika/store_value` JSON — *not* a network protocol.
- **Persistence**: Proto DataStore (sessions, settings, dashboards) + Room (critical sensors cache).
- **Push**: Firebase Cloud Messaging + two notification channels (normal / critical‑bypass‑DnD).
- **Widgets**: Glance (Compose for widgets), sizes 2×2 / 3×2 / 3×3 / 4×3.
- **Billing**: Google Play Billing 7.1.1, subscription products (P1W / P1M / P1Y).
- **Protection**: PairIP license check (anti‑tamper).

---

## 2. The wire protocol (reusable verbatim on iOS)

This is the highest‑value artifact: the exact protocol our iOS client must speak. It is HA's WebSocket API plus the `domika/*` extension.

### 2.1 Connection & auth handshake
- URL: `ws(s)://<ha-host>:<port>/api/websocket` (wss if the stored URL is https). Header `Content-Type: application/json`.
- Standard HA handshake:
  1. server → `{"type":"auth_required"}`
  2. app → `{"type":"auth","access_token":"<HA OAuth access token>"}`
  3. server → `{"type":"auth_ok"}` (else `auth_invalid` → fail)
- Every subsequent command carries a monotonically increasing numeric `"id"`.

### 2.2 Standard HA commands used
`get_config`, `get_panels`, `lovelace/config` (`{url_path, force}`), `config/area_registry/list`, `config_entries/get`, `config_entries/disable`, `subscribe_events` (`{event_type}`), `call_service` (`{domain, service, target:{entity_id}, service_data}`), `camera/stream` (`{entity_id}`), plus HACS: `hacs/repositories/list`, `hacs/repositories/add`, `hacs/repository/download`.

### 2.3 CUSTOM `domika/*` commands (the integration's API)
| Command (`type`) | Payload | Purpose |
|---|---|---|
| `domika/update_app_session` | `app_session_id, push_token_hash, os_platform, os_version, app_id, app_version` | Register/refresh the session; returns session + reachable URLs |
| `domika/remove_app_session` | `app_session_id` | Logout |
| `domika/update_push_token` | `app_session_id, push_token_hash` | Update push token (hash) |
| `domika/update_push_session_v2` | `app_session_id, push_environment, transaction_environment, platform, push_token_hex, transaction_id` | Register **raw** token + entitlement for the cloud push relay |
| `domika/verify_push_session` | `app_session_id, push_token_hash, verification_key` | Prove token liveness (closes push verification loop) |
| `domika/remove_push_session` | `app_session_id` | Deregister push |
| `domika/resubscribe` | `app_session_id, subscriptions:{ "<entity_id>": { "<attr_code>": <priority 0=SOCKET,1=PUSH> } }` | The core live‑state subscription |
| `domika/critical_sensors` | – | One‑shot list of critical sensors |
| `domika/entity_list` | `domains:[]` | Browse entities by domain (add‑applet picker) |
| `domika/entity_info` | `entity_id` | Entity metadata |
| `domika/entity_state` | `entity_id` | Single entity state |
| `domika/store_value` | `hash, key, value, app_session_id` | Cross‑device sync store (keys: `app.dashboards`, `_smileyHiddenIds`) |
| `domika/get_value` | `key` | Read synced value |

**`AppSessionIdIncomeResult`** returns: `app_session_id, old_app_session_ids[], local_ip_port, local_url, external_url, internal_url, cloud_url, critical_push_sensors_present` — lets the client pick the reachable URL (LAN vs Nabu Casa cloud).

### 2.4 Realtime state model (the efficient bit)
- `domika/resubscribe` sends `{entity_id: {attr_code: priority}}`. Priority **0 (SOCKET)** = pushed live over the socket (entities visible now); **1 (PUSH)** = delivered via push notification when backgrounded. Attribute codes are compact (`s`=state, `a.brightness`, `a.current_temperature`, `a.device_class`, …).
- The integration streams changes as `event` frames whose `data` maps `entity_id`→changed attributes, or `EntitiesUpdated` batches. The client relies on this custom subscription rather than raw `state_changed` firehose.

### 2.5 Critical sensors
- On connect: `subscribe_events` for `domika_critical_sensors_changed` (global) and `domika_<sessionId>` (per‑session), plus one `domika/critical_sensors` poll.
- Payload `CriticalSensorsChanged`: `{sensors:[{entity_id,name,type,device_class,state,timestamp}], sensors_on:[entity_id]}` where `type` ∈ `normal|warning|critical`.
- **Criticality is decided server‑side** (by the integration, based on HA `device_class`: `smoke, gas, carbon_monoxide, moisture, heat, safety`). The app has **no** UI to mark a sensor critical.

### 2.6 Control commands (per‑domain)
Sent as `call_service` (or REST `UpdateEntity`). Confirmed catalog:
- **light**: turn on/off, brightness, hs color, color temp, effect
- **switch**: turn on/off
- **cover**: open, close, set position
- **lock**: lock/unlock
- **climate/thermostat**: set mode, target temp, fan mode, preset mode, humidity, toggle
- **media_player**: turn on/off, set volume, set source
- **scene**: activate
- **camera**: get stream URL (HLS)
- **sensor / binary_sensor**: read‑only

### 2.7 Reconnect/resilience
- Heartbeat: `ping` every 10 s; track `pong`; if no pong within the interval → tear down & reconnect.
- Backoff: linear `min(count×3000ms, 30000ms)`, reset on success.
- One socket + one HTTP client cached per home; single `id` counter per socket.

---

## 3. Auth flow (→ iOS `ASWebAuthenticationSession`)

Standard HA **OAuth2 (IndieAuth)** against the *user's own server*:
- `client_id = https://login.domika.app` (an identifier URL, not a contacted endpoint)
- `redirect_uri = domikaapp://login.domika.app/login/redirect` (custom scheme)
- Authorize at `https://<user-ha>/auth/authorize?client_id=…&redirect_uri=…` → code → exchange at `https://<user-ha>/auth/token` → `{access_token, refresh_token, expires_in}` → refresh via `/auth/token`.

**iOS:** use `ASWebAuthenticationSession` with our own scheme (e.g. `havenapp://…/login/redirect`) and our own `client_id` URL (e.g. `https://login.<ourdomain>`). Store tokens in **Keychain**. A `HomeSession` = `{homeId, name, authUrl, baseUrl/localUrl/externalUrl, accessToken, refreshToken, sessionId}`.

---

## 4. Onboarding & the HACS/integration bootstrap

`InitialViewModel` runs a **connect‑time state machine** driven by exceptions thrown during `checkConfiguration` (`get_config` → `hacs/repositories/list` → `config_entries/get`):

| Condition | Screen / action |
|---|---|
| `Unauthorized` | OAuth login |
| mDNS finds instances | Offer discovered `_home-assistant._tcp` servers (else manual URL) |
| `HacsNotInstalledException` (unknown command `hacs/*`) | **Install HACS** guide (`installhacs`) |
| `DomikaNotInstalledException` (no repo domain `domika`) | **Install integration**: auto `hacs/repositories/add` + `hacs/repository/download` of `DevPocket/domika-hacs` |
| `DomikaIsDisabledException` | Enable integration (`config_entries/disable` false) |
| `NeedToBeAdministratorException` | "must be admin" screen |
| `UserIsLocal` | local‑only account screen |
| `ServerUnavailableException` | retry |
| `HasSubscriptionUseCase` | paywall gate |

**Local discovery:** `LookupLocalInstancesDataSource` uses Android NsdManager to browse `_home-assistant._tcp` (a V34 variant handles Android 14). **iOS:** `NWBrowser` / Bonjour for the same service type.

---

## 5. Dashboard & renderer system

### 5.1 Data model (proto today; ours can be Codable/SwiftData)
```
HomeDashboards → Dashboards → Dashboard{ id, name, icon, modules[] }
                              Module{ id, name, icon, isHidden, layoutKind, applets[] }   // "Module" == "Section" in UI
                              Applet{ id, title, icon, size(SMALL|MEDIUM|LARGE), <oneof type> }
```
- A **Dashboard** is a list of **Modules/Sections**; each Section is a list of **Applets** (tiles). Applets render at three sizes.
- Dashboards are persisted locally *and* synced across devices via `domika/store_value` key `app.dashboards` (a serialized blob). Edits: add/rename/reorder/delete sections and applets; insert/replace applet positions.

### 5.2 Renderer (applet) catalog — the iOS view catalog to build
Each applet = one SwiftUI tile bound to one HA entity domain, reading typed attributes and emitting the §2.6 commands:

| Applet | HA domain | Reads (attributes) | Controls |
|---|---|---|---|
| **Light** | `light` | on/off, brightness, hs_color, color_temp, effect_list | toggle, brightness slider, color/temp picker, effects |
| **Switch** | `switch` | on/off | toggle |
| **Cover** | `cover` | position, state (open/closed/opening) | open/close/stop, position slider |
| **DoorLock** | `lock` | locked/unlocked/jammed | lock/unlock |
| **Thermostat** | `climate` | current/target temp, hvac mode, fan mode, preset, humidity, unit | setpoint, mode, fan, preset |
| **MediaPlayer** | `media_player` | state, volume, source, media info | play/pause/power, volume, source select |
| **Scene** | `scene` | – | activate |
| **Sensor** | `sensor` | value, unit, device_class | read‑only value |
| **Sensors** | multiple `sensor` | list of values | read‑only aggregate tile |
| **BinarySensor** | `binary_sensor` | on/off, device_class | read‑only status |
| **Camera** | `camera` | stream URL (HLS via `camera/stream`) | live view (→ `VideoActivity`; iOS `AVPlayer`) |
| **Dummy / NonSpecific** | any/unsupported | state string | **graceful fallback** tile for entities without a dedicated renderer |

The **Dummy/NonSpecific** applet is important: unsupported cards/entities degrade gracefully instead of failing.

### 5.3 Dashboard import from HA (Lovelace)
- `get_panels` → enumerate Lovelace dashboards (`component_name == "lovelace"`, `title`, `url_path`).
- `lovelace/config {url_path, force}` → the dashboard's views & cards (`HAView` DTO).
- The importer walks views/cards, extracts referenced `entity_id`s, and maps each to the best‑fit applet by the entity's domain (light→Light, climate→Thermostat, …), falling back to NonSpecific. Views become Sections. This bootstraps a Domika dashboard from the user's existing HA setup so they don't build from scratch.

### 5.4 Design system (`uikit`)
- Applet primitives: `AppletUiControl`, `AppletUiCommand`, `AppletViewState`, `AppletIcon`/`AppletIconLayer` (layered icons), `AppletColors`, `AppletDimension` (SMALL/MEDIUM/LARGE), `AppletMode`.
- State conventions to mirror: on/off/unavailable coloring, per‑domain accent colors (`SensorColors`), MDI icon rendering (HA `mdi:` icon set — we'll need an MDI icon font/asset pipeline on iOS).

---

## 6. Push notifications (→ APNs + Critical Alerts)

Pipeline: **app → (WebSocket domika/*) → HA/domika‑hacs → Domika cloud → FCM/APNs → device.** The app registers its push token with HA over the socket; the integration + cloud do the actual delivery.

- Token: FCM today. Two forms sent — **hashed** `push_token_hash = SHA256(push_environment + os_platform + token)` in `update_app_session`/`update_push_token`, and **raw** `push_token_hex` in `update_push_session_v2` (with `platform`, `push_environment`, and a Play Billing `transaction_id` for entitlement).
- Verification handshake: cloud sends a silent push containing `verification_key` (+ `original_transaction_id`); app responds so the backend confirms liveness (→ `domika/verify_push_session`).
- Channels: `domika_common_channel_id` (IMPORTANCE_DEFAULT) vs `domika_critical_channel_id` (IMPORTANCE_HIGH, `setBypassDnd(true)` when notification‑policy access granted). Server picks the channel via `android_channel_id` in the payload.

**iOS mapping:**
- Replace FCM with **APNs** (register `UIApplication`/`UNUserNotificationCenter`, get device token; `platform="ios"`, `os_platform="ios"`).
- **Critical Alerts entitlement** (`com.apple.developer.usernotifications.critical-alerts`, requires Apple approval) → set `interruption-level: critical` so fire/leak alerts bypass silent/Focus/DnD. Normal alerts use `time-sensitive`/`active`. This is the iOS analog of the bypass‑DnD channel.
- StoreKit transaction id substitutes the Play `transaction_id` in `update_push_session_v2`.

---

## 7. Widgets (→ WidgetKit + App Intents)

- Domika reuses applets inside home‑screen widgets (Glance), configured via `WidgetActivity` + `PbWidgetConfiguration`, in 2×2 / 3×2 / 3×3 / 4×3 grids. Widget taps perform actions directly (Glance actions) or open the app.
- **iOS:** **WidgetKit** for the tiles + **App Intents** for interactive controls (iOS 17+ interactive widgets) so a tap can toggle a light without opening the app. **Control Center / Lock Screen controls** (iOS 18 `ControlWidget`) and **Live Activities** are strong differentiators for the "critical sensor active" case. Widget state refresh via `WidgetKit` timeline + push‑to‑reload (APNs background push / `reloadTimelines`).

---

## 8. Billing (→ StoreKit 2)

- Play Billing subscriptions with `P1W`/`P1M`/`P1Y` periods; `HasSubscriptionUseCase` gates the app; `SelectSubscription` paywall screen. Subscription touches dashboard/manage/widgets/help/onboarding paths, and the entitlement `transaction_id` is threaded into push registration.
- **iOS:** **StoreKit 2** subscription group (weekly/monthly/yearly), `Transaction.currentEntitlements` for gating, and pass the StoreKit transaction id into `update_push_session_v2`.

---

## 9. Screen inventory (→ SwiftUI views)

From `AppNavigation`: Initial/Splash → SelectHome (add/discover/OAuth) → OpenDomikaInstallation / InstallHacs / NeedToBeAdministrator / UserIsLocalOnly (bootstrap gates) → **Dashboard** (main) → ManageDashboard (sections) → SelectApplet (entity picker) → SelectAppletSize → EditApplet → EditSensors → ConfigureWidget → SelectSubscription (paywall) → Settings / About / Help → Video (camera fullscreen). Multi‑home: SelectHome / ManageHome + active‑home store; `SwitchToAnotherHomeUseCase`.

---

## 10. Proposed iOS architecture (HavenApp)

Mirror the clean layering with idiomatic Apple tech:

- **Language/UI:** Swift 6 + **SwiftUI**, `@Observable` (Observation), Swift Concurrency (async/await, `AsyncStream`, actors).
- **Layers:**
  - `Core/Networking` — `HAWebSocketClient` (built on `URLSessionWebSocketTask`, an `actor` owning the id counter + heartbeat + reconnect), `HARestClient`, JSON `Codable` message types, the `domika/*` (→ our `haven/*`) command set.
  - `Core/Domain` — entity models, applet models, use cases (as plain async functions/services).
  - `Core/Persistence` — **SwiftData** (or GRDB) for dashboards/sessions/critical‑sensor cache; **Keychain** for tokens.
  - `Features/*` — one SwiftUI screen module each (MVVM with `@Observable` view models).
  - `DesignSystem` — applet tiles, MDI icon pipeline, colors, sizes.
  - `Widgets` — WidgetKit extension + App Intents (shared models via an App Group).
  - `Push` — APNs registration + Notification Service/Content extensions for critical alerts.
- **DI:** lightweight (init injection / a small container), no Hilt equivalent needed.
- **Wire compatibility:** the `Codable` message layer should match the protocol in §2 field‑for‑field so we can talk to the same class of integration.

---

## 11. Where HavenApp should DIFFER (decision points)

You said "meaningful differences." The analysis exposes the forks that most change the plan — flagged here, with the big three needing your call before I write the build plan:

1. **Backend/integration strategy (biggest fork).** Domika's efficiency and push depend on the `domika-hacs` integration + Domika cloud. Options:
   - (a) **Own integration + own cloud** (`haven-hacs` + our push relay) — full control, most work, true "ground‑up."
   - (b) **Pure HA‑native, no custom integration** — talk only to stock HA WebSocket/REST; simpler, installs with zero server‑side steps, but loses efficient batched subscriptions and *loses server‑pushed critical notifications* (would need a different push mechanism, e.g. the official HA mobile_app/`notify` integration or local‑only alerts).
   - (c) **Reuse `domika-hacs`** — fastest, but ties us to a competitor's integration/cloud and its terms.
2. **Notification transport.** Cloud relay (like Domika) vs. leveraging HA's built‑in `mobile_app` push (the official Companion app's mechanism) vs. local‑network alerts.
3. **Primary product angle / differentiation.** e.g. iOS‑18 Control Center & Lock‑Screen controls, Live Activities for active alarms, Apple Watch app, Siri/App Intents automation, a fundamentally different dashboard paradigm, HomeKit bridging, or a privacy/local‑only stance (no cloud at all).
4. Smaller diffs to decide later: SwiftData vs GRDB; whether to keep the paywall; whether to support multiple homes at launch.

---

## 12. Suggested phasing (once §11 is decided)

- **P0 – Spike:** OAuth login → HA WebSocket handshake → `get_states` → render one live Light tile with toggle/brightness. Proves the transport end‑to‑end.
- **P1 – Read/control core:** full renderer catalog (§5.2), manual dashboard build (sections + applets), reconnect/heartbeat.
- **P2 – Efficiency + import:** batched subscription (our `resubscribe` analog), Lovelace dashboard import.
- **P3 – Push:** APNs + Critical Alerts + push registration/verification handshake (depends on §11.1/§11.2).
- **P4 – Widgets & controls:** WidgetKit tiles + App Intents + Control Center/Lock‑Screen controls + Live Activities.
- **P5 – Multi‑home, settings, paywall (StoreKit 2), polish.**

---

## 13. Risk & legal notes

- **Integration dependency:** if we reuse `domika-hacs`/Domika cloud (§11.1c) we inherit their availability and ToS. Recommend our own integration for a shippable product.
- **Critical Alerts** require an Apple entitlement request with justification (safety use‑case is a strong case) — start that approval early.
- **HA breadth:** HA has 40+ entity domains; Domika supports ~12. Our NonSpecific fallback keeps us safe, but scope the renderer catalog explicitly.
- This analysis is for **interoperability** (building a compatible independent client); we reused Domika's *protocol and architecture patterns*, not its code or assets.

---

## Appendix – Analysis artifacts (local)
- APK/XAPK + splits: `domika_analysis/apk/` (v1.0.22)
- Decompiled sources (jadx): `domika_analysis/jadx_out/sources/com/devpocket/domika/`
- Decoded manifest/resources (apktool): `domika_analysis/apktool_out/`
