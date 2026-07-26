# HavenApp Sub-project B — `hacs-havenapp` Integration (Design)

> **Status:** Design approved 2026-07-25, pending written-spec review.
> **Scope:** The Home Assistant custom integration (Python, distributed via HACS) that gives HavenApp a server-side home: configuration storage/sync with a multi-user model, and the foundation for later server-side logic (critical-sensor evaluation, notification rules, efficient subscriptions).
> **Predecessors:** `2026-07-25-havenapp-product-definition-design.md` (A), `2026-07-25-havenapp-subproject-d-renderers-dashboard-design.md` (D, shipped). Reference: `docs/domika-analysis-and-ios-plan.md` documents how Domika's equivalent integration works.

---

## 1. What this is

A Home Assistant **custom integration** named `haven`, installed via **HACS** from its own repository `hacs-havenapp`, that registers a small set of `havenapp/*` WebSocket commands. It runs entirely inside the user's own Home Assistant.

**There is no Haven-operated server anywhere in this design.** HA is the single source of truth for Haven's configuration; the iOS app's local cache is read-through only. This is the concrete implementation of the product spec's privacy/local-first commitment (product-def §4.6, §10).

## 2. Decisions taken (and why)

| Decision | Choice | Rationale |
|---|---|---|
| **Required or optional?** | **Required.** HavenApp does not function without it. | Matches Domika's model and keeps the client simple (one code path, always assume the API). Cost is accepted: see §3. |
| **Repo location** | **Separate repo `hacs-havenapp`.** | HACS custom repositories are installed by URL and expect the integration at the repo root. Clean separation of Python/HA from Swift/iOS, with its own CI. |
| **First-iteration scope** | **Integration skeleton + config storage API only.** | Nothing consumes Haven config yet (config mode is a later sub-project). Build the pipeline and the storage contract; do not guess at features. |
| **Storage discipline** | **Split by whether the server acts on it** (§5). | Pure opaque blobs would block the server-side logic that Sub-project F genuinely requires; full server-side schemas would make every UI iteration cost an integration release and an HA restart. |
| **Multi-user model** | **Shared base + limited personal overlay**, three scopes (§5.2). | The curated house dashboard is shared and consistent for everyone; only limited personal things (e.g. pinned devices) vary. |
| **Concurrency** | **Optimistic, version/etag based.** Stale writes are rejected, never merged silently. | Prevents one phone silently clobbering another's edits. |

## 3. Consequences of "required" — a hard prerequisite, stated plainly

Making the integration required means **HavenApp cannot ship to real users until the client has onboarding gates**: detect HACS → detect `havenapp`→ check the user is an admin → drive the guided install. Until then the app fails against a plain Home Assistant.

This is client-side work belonging to a later sub-project, but B must ship the **detection surface** it depends on — that is `havenapp/info` (§6).

**Version-skew mitigation and its limits.** The app checks `havenapp/info` at connect and can drive HACS to install a required version (`hacs/repository/download`), the same mechanism Domika uses to bootstrap its own install. This is a real improvement over "users silently run ancient versions forever", but it is not free:
- Loading new integration code **requires an HA restart** (~30s of the whole house's HA being down). Not a silent background update.
- It is **admin-only**. A non-admin household member hitting a version mismatch is blocked until an admin resolves it — which matters precisely because we support multi-user households.
- It can fail (network, HACS issues), so a hard version gate turns a transient failure into "app unusable".

**Therefore:** prefer designs that rarely need an integration release. Feature-gate on `capabilities` rather than raw version comparisons, so the app degrades a feature instead of hard-blocking. This is the reasoning behind the storage split in §5.

## 4. Scope boundary

**In scope (B's first iteration):**
- Installable, tested HACS integration: `manifest.json`, `hacs.json`, UI config flow (single instance, no options), release workflow.
- The capability handshake `havenapp/info`.
- The config storage API: `havenapp/config/get` / `set` / `delete`, with scopes, optimistic concurrency, and permission rules.
- Persistence via HA's own `homeassistant.helpers.storage.Store`.
- Unit tests via `pytest-homeassistant-custom-component`, plus a manual HACS install verification.

**Explicitly NOT in B's first iteration** (Domika has these; we add them when something needs them):
- Efficient batched entity subscriptions with priority tiers — an optimization we have not measured a need for.
- Push/session registration and critical-sensor evaluation — Sub-project F.
- Entity browsing/metadata commands — the app uses HA's own registries today and they work.

**Reserved namespaces** (designed, not built): `havenapp/rules/*`, `havenapp/subscriptions/*`.

## 5. Storage model

### 5.1 Split by whether the server acts on it

This is the central design decision. Two payload disciplines share one storage mechanism and one envelope.

**Category A — server-aware, structured.** Anything the integration must *understand and act on*, typically while the app is backgrounded or offline:
- which sensors are critical, and their thresholds
- notification rules
- subscription/priority preferences

These get real schemas, server-side validation, and server-side logic. **Changing them costs an integration release plus a house-wide HA restart**, so keep this category as small as possible and change it rarely. Near-term, it is expected to be nearly empty.

**Category B — client presentation state; structured envelope, opaque payload.** The dashboard itself: floors, sections, tile positions and sizes, labels, composite-device definitions.

The integration stores these blobs and never parses them. The iOS app owns the schema and its migrations. This is where schema churn is highest — every UI iteration touches it — and keeping it opaque means dashboard changes ship in an **App Store update alone**: no integration release, no HA restart. **v1 lives almost entirely in category B.**

### 5.2 Record shape and scopes

```
Record = {
  scope:      "shared" | "user:<ha_user_id>" | "device:<installation_id>",
  key:        string,          # client-defined namespace, e.g. "dashboard", "prefs"
  version:    int,             # monotonic, server-assigned, incremented per successful write
  updated:    timestamp,       # server-assigned (UTC)
  updated_by: <ha_user_id>,
  owner_user_id:  <ha_user_id>?,   # device scope only — set on first write (§5.5)
  owner_token_id: <token_id>?,     # device scope only — when available (§5.5)
  payload:    JSON             # category A: schema-validated; category B: opaque
}
```

**Three scopes.** The important one is `shared`: it carries the curated, house-centric dashboard that everyone in the household sees, consistently. The other two exist so the client can decide per feature, later, without another integration release:
- `user:<ha_user_id>` — personal state that should follow a person across their devices (e.g. pinned rooms).
- `device:<installation_id>` — genuinely per-device state (e.g. which widgets this iPhone shows). `installation_id` is a client-generated UUID, stable per app install.

### 5.3 Concurrency

Every write carries the `base_version` it was derived from.
- If `base_version` matches the stored `version`, the write succeeds and `version` increments.
- If it does not, the write is **rejected**. `set` returns a *discriminated result* — `{status: "version_conflict", current: {...}}` — rather than a protocol error, because a conflict is an expected outcome that carries data and HA's `send_error` cannot attach a payload. The client reapplies its change onto `current` and retries, with no extra refetch.
- A write to a key that does not exist yet uses `base_version: 0`.

No silent last-write-wins, and no server-side merging (impossible for opaque category-B payloads anyway).

### 5.4 Permissions

- **Read** `shared`: any authenticated HA user.
- **Write** `shared`: **HA admins only.** This mirrors HA's own permission model — the person curating the house dashboard is the admin.
- **Read/write** `user:<id>`: only that user.
- **Read/write** `device:<id>`: **bound to an owner**, established on first write (trust-on-first-use) and enforced thereafter — see below.

Permission failures return a distinct error code so the client can explain *why* rather than showing a generic failure.

### 5.5 Device-scope ownership binding

The `installation_id` is a client-generated UUID and must **not** be treated as a secret — UUIDs travel in backups, logs and diagnostics. Its job is namespacing, not authorization. Authorization is bound to identity the server can verify:

**On first write** to `device:<installation_id>`, the record is stamped with an owner:
```
owner_user_id:  <ha_user_id>          # always recorded
owner_token_id: <refresh_token_id>    # recorded when available (see below)
```
**On every subsequent read or write**, the caller must match the recorded owner. A mismatch returns `not_authorized`. This means another household member cannot read or manipulate your device record even if they learn its id.

**Preferred binding — HA's own per-install identity.** HavenApp performs a fresh OAuth login per install, and Home Assistant issues a **distinct refresh token per login**, so HA already holds a per-install identity we do not have to invent or store a secret for. Where the WebSocket connection exposes the calling `refresh_token_id`, bind to it: then even the same user's *other* device cannot write this device's record, and there is no bearer secret in the client to leak, sync or rotate.

> **Verified (2026-07-25):** `ActiveConnection.refresh_token_id` is present in Home Assistant 2026.7.4 (`websocket_api/connection.py`), so the per-install binding is real and is implemented. A test proves the same user's *second* install cannot write the first's device record. The code still degrades to `owner_user_id`-only binding if the attribute is ever absent.

**Reclaiming a record.** Because binding is trust-on-first-use, a reinstalled app generating a new `installation_id` simply creates a new record; the orphaned one is inert and owned by nobody reachable. Clients should not attempt to "take over" an existing device record — if the owner check fails, treat the id as unusable and generate a fresh one rather than adding a takeover path (which would reintroduce exactly the hole this closes).

## 6. Wire API

All commands are registered under the `havenapp/` namespace via HA's `websocket_api` decorators and require an authenticated connection.

| Command | Payload | Returns |
|---|---|---|
| `havenapp/info` | — | `{integration_version, schema_version, capabilities: [string], ha_user_is_admin: bool}` |
| `havenapp/config/get` | `scope, key` | `{version, payload, updated, updated_by}` — or `null` if absent |
| `havenapp/config/set` | `scope, key, base_version, payload` | `{status: "ok", version}` — or `{status: "version_conflict", current: {...}}` |
| `havenapp/config/delete` | `scope, key` | `{ok: true}` |

`havenapp/info` is the linchpin: it is how onboarding detects the integration at all, how the app decides whether to drive a HACS update, and how it feature-gates. **`capabilities` is a list of opaque feature strings** (e.g. `"config.v1"`), so the app can light features up progressively rather than hard-gating on version arithmetic. `ha_user_is_admin` lets the app show a non-admin household member something sensible instead of a confusing write failure.

**Error codes** are explicit and distinguishable: `version_conflict`, `not_authorized`, `invalid_scope`, `not_found`.

## 7. Architecture

```
hacs-havenapp/                       # separate repo, HACS custom repository
├─ custom_components/havenapp/
│  ├─ manifest.json                  # domain "haven", version, iot_class, dependencies
│  ├─ __init__.py                    # async_setup_entry: init store, register WS commands
│  ├─ config_flow.py                 # single-instance UI setup, no options
│  ├─ const.py                       # DOMAIN, STORAGE_KEY/VERSION, CAPABILITIES, error codes
│  ├─ store.py                       # ConfigStore: scoped records, versioning, permissions
│  └─ websocket_api.py               # haven/info, haven/config/{get,set,delete}
├─ hacs.json                         # HACS metadata
├─ tests/                            # pytest-homeassistant-custom-component
└─ .github/workflows/                # lint + tests + release
```

Each unit has one clear job: `store.py` is pure storage logic (scopes, versioning, conflicts) and is testable without any WebSocket plumbing; `websocket_api.py` is a thin, well-validated transport layer over it; `config_flow.py` only handles setup. Permission checks live at the transport boundary, where the calling user is known.

**Persistence** uses `homeassistant.helpers.storage.Store` — HA's standard mechanism. It gives atomic writes, its own schema versioning/migration hook, placement in `.storage/`, and inclusion in HA backups. No custom file handling.

## 8. Testing

- **`pytest` + `pytest-homeassistant-custom-component`** — the standard harness for HA custom integrations. It provides a real in-process `hass` fixture, so WebSocket commands are tested end-to-end rather than mocked.
- **Coverage that matters:** round-tripping a payload; version increments; a stale write is rejected and returns current state; a non-admin cannot write `shared` but can read it; a user cannot read another user's `user:` scope; a second user cannot read or write a `device:` record owned by someone else, and first-write ownership binding is applied; unknown scope rejected; delete then get returns null; `havenapp/info` reports version and capabilities.
- **Manual verification (the part tests cannot prove):** install into the real Home Assistant via HACS as a custom repository, confirm it appears, sets up through the UI config flow, survives an HA restart, and that the iOS app can call `havenapp/info` against it.

## 9. Success criteria

- The integration installs into a real HA via HACS custom repository and completes UI setup with no YAML.
- `havenapp/info` returns a version and capability list to an authenticated client.
- A config blob written from one client is readable by another, and survives an HA restart.
- Two clients editing the same key: the second write is rejected with a conflict carrying current state, and no data is silently lost.
- A non-admin household member can read the shared dashboard but cannot overwrite it, and receives a distinguishable authorization error.
- Unit tests green in CI.

## 9a. Delivered (2026-07-25)

Built and pushed to `hacs-havenapp` (commit `d424598`): the integration skeleton, all four commands, scoped storage with ownership binding, and **10 tests against a real in-process Home Assistant 2026.7.4**. Naming settled as repo `hacs-havenapp`, HA domain `havenapp`, commands `havenapp/*`.

Still outstanding: the **manual HACS install** into a real Home Assistant (§8) — the one thing tests cannot prove.

## 10. Open questions / follow-ups

- **Client onboarding (blocking for release, not for B):** detect-HACS → detect-`haven` → admin check → guided install/update flow, including the HA-restart step. Belongs to a client sub-project; B provides `havenapp/info` as its detection surface.
- **What actually goes in each scope** is a client decision deferred until config mode exists — the storage layer deliberately supports all three so it need not be settled now.
- **Category A's first real content** arrives with Sub-project F (critical-sensor rules). Expect the schema-versioning and forced-update path to get its first genuine exercise then.
- **`installation_id` generation and stability** across app reinstall/restore is a client concern to define alongside device-scoped features. Note it is a namespace, not a secret (§5.5) — a reinstall generating a fresh id is expected and harmless.
- The efficiency work (batched subscriptions with priority tiers) remains unbuilt and unmeasured; revisit only if a large home shows a real problem.
