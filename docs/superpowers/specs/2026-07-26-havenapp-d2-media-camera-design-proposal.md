# D.2 — Media Player & Camera renderers — DESIGN PROPOSAL

> **Status: UNAPPROVED. Staged for review.** Written overnight 2026-07-26 while you
> were asleep, per "propose designs, build, stage for review." Nothing here is
> built yet — deliberately. Both renderers involve judgment calls I expect you to
> want to change, and building before you've seen them wastes the rework.
>
> Approved-but-unbuilt D.2 items (colour-temperature bar, accessibility pass) are
> *not* in this document; those are just work, and don't need your review first.

Extends the D spec (`2026-07-25-havenapp-subproject-d-renderers-dashboard-design.md`),
which deferred both renderers in §9/§10b.

---

## 1. What makes these two different from every renderer built so far

Nine renderers ship today (Light, Switch, Cover, Lock, Climate, Scene/Script,
Sensor, Binary Sensor, Generic). Every one of them fits a shape you approved
early: **the primary on/off always lives in the modal header**, secondary controls
live in body `FacetCard`s, and a tile conveys state through colour and an optional
level bar.

Media Player and Camera both break that shape, in different ways:

- A **media player's** primary action is *play/pause*, not on/off. Its most
  important content isn't a control at all — it's *what's playing*.
- A **camera** has essentially no controls. It's a continuous image. It's also the
  only entity type in the app with a genuine privacy dimension.

So the interesting question for both isn't "which controls" — it's how far to bend
the established pattern. My bias is to bend as little as possible, and I've flagged
the two places I think bending is genuinely warranted.

---

## 2. Media Player

### 2.1 Tile

Default size **2×1**. A 1×1 media tile can show either artwork or text, not both,
and neither alone answers "what's playing?" — which is the only question a glance
at a media tile is asking.

```
┌─────────────────────────────────┐
│ ▉▉▉▉  Kind of Blue          ▶  │   artwork · title/artist · play-pause
│ ▉▉▉▉  Miles Davis               │
└─────────────────────────────────┘
```

- **1×1** offered but not default: icon + name + a small state dot. Honest about
  being a launcher, not a display.
- **2×2** for a room where media is the point: larger artwork, full transport row,
  volume bar.

Artwork comes from `entity_picture`, which is a **relative** path needing the base
URL and an auth token (see §4). When absent — radio streams, most TTS targets — fall
back to a domain icon on the accent colour rather than an empty grey box.

State → colour follows the existing convention: `playing` accented, `paused`
accented-dim, `idle`/`standby` calm, `off` neutral, `unavailable` the calm
treatment (which the app still lacks generally — D spec §10b item 3).

### 2.2 Modal

Header stays exactly as the scaffold defines it, with one decision:

> **Decision — the header toggle maps to power, not play/pause.** `media_player`
> supports `turn_on`/`turn_off` only sometimes (`supported_features` bit 0x80/0x100).
> When unsupported, the header shows **no toggle at all** rather than repurposing it
> for play/pause. Repurposing would make the same control mean different things on
> different devices — the exact inconsistency you pushed back on when the switch
> control wasn't in the header.

Body, in order:

1. **Now-playing card** — artwork, title, artist/album, and a **progress bar**.
   Progress needs interpolation: HA gives `media_position` plus
   `media_position_updated_at`, and the position only re-reports on change, so a
   naive render freezes. Ticking locally from that timestamp is required, and it
   must stop when paused.
2. **Transport row** — previous / play-pause / next, play-pause visually dominant.
   Each is gated on its own `supported_features` bit; unsupported controls are
   omitted, not disabled-and-greyed.
3. **Volume** — horizontal slider plus a mute button. *Not* the vertical bar; that
   idiom you approved is specifically for the room-detail sub-section layout.
4. **Source / sound mode** — `HavenSegmented` when there are ≤4 options, a menu
   beyond that. Real receivers have a dozen sources and a segmented control would
   be unusable.

### 2.3 Deliberately excluded from v1

- **Speaker grouping** (`join`/`unjoin`). Genuinely useful in a multi-room house,
  and genuinely its own design problem — it's a *relationship between* entities,
  which nothing in the current model expresses. Worth its own pass.
- **Browsing media** (`media_player/browse_media`). A file-browser tree is a
  different app surface, not a control modal.
- **TTS / play-media targets.** Better served by the Actions surface than by a tile.

---

## 3. Camera

### 3.1 Tile — still image, not live

Default **2×2**. A camera tile smaller than that is a thumbnail of a thumbnail.

The tile shows a **periodically refreshed still**, not a live stream. Three reasons,
in order of weight:

1. **Power and data.** A dashboard with four cameras holding four live streams is a
   battery and bandwidth sink for a view that's usually glanced at for two seconds.
2. **Load on your HA.** Every stream is transcoding work on the server your house
   runs on.
3. Stills are simply enough to answer "is anyone at the door?"

Refresh every ~10s while the tile is on screen, and **stop entirely when the app
backgrounds or the tile scrolls out of view**. Snapshot via
`/api/camera_proxy/<entity_id>` (authenticated — §4).

### 3.2 Modal — live, and visibly so

Tapping opens a live view. HA exposes HLS through the `camera/stream` WebSocket
command, which returns a relative stream URL playable by `AVPlayer`. MJPEG via
`/api/camera_proxy_stream/` is the fallback for cameras without `stream` support.

> **Decision — a live camera says so.** A small "LIVE" indicator whenever a stream
> is actually running, and the stream tears down on dismiss rather than lingering.
> This is the one place I'd add chrome the other renderers don't have. A camera is
> the only entity in this app where *the user not knowing it's active* is a real
> problem rather than a cosmetic one — and it's the difference between a camera
> feature that feels trustworthy in a home and one that doesn't.

Also in the modal: a full-bleed aspect-correct frame, and — where the camera
reports them — the related `binary_sensor` motion/person entities as chips, since
"the camera is showing nothing but motion fired 30s ago" is exactly when you look.

### 3.3 Deliberately excluded from v1

PTZ controls, recordings/event playback, and two-way audio. Each is a substantial
surface, and all three are heavily integration-specific (`onvif`, `frigate`,
`unifiprotect`) rather than standard `camera` domain features.

---

## 4. The one shared technical problem — authenticated image loading

Both renderers need it, and the app has nothing for it today.

`entity_picture` and `/api/camera_proxy/` are **relative paths on the HA instance
requiring the access token**. `AsyncImage` cannot attach an `Authorization` header,
so it will silently 401 and render its placeholder — a blank tile that looks like a
camera with nothing to show rather than an error.

So D.2 needs a small authenticated image loader: resolve relative → absolute
against the *current* base URL, attach the bearer token, cache in memory, and
**cancel on disappear**.

Two constraints that fall directly out of tonight's connection work:

- It must take its base URL and token from `TokenProvider`, *not* capture them once.
  The app now fails over between local and remote mid-session, and a URL captured at
  view-construction time will point at the wrong host after a failover.
- It must not log or persist the token in image-cache keys.

**This loader is a prerequisite for both renderers and should be built and tested
first, on its own.** It's also the piece most likely to be got subtly wrong, and —
unlike the SwiftUI views — it's pure enough to unit-test properly.

---

## 5. Open questions for you

1. **Do you have cameras in HA at all, and which integration?** If none, Camera
   drops down the priority list — I'd rather spend the time on the entity-curation
   problem you raised (D spec §11), which affects every screen.
2. **Media players — which, and do you group them?** Sonos/AirPlay multi-room makes
   the excluded grouping feature (§2.3) the *most* valuable part rather than a
   deferral, and I'd revisit that call.
3. **Is a 2×2 camera tile on the room dashboard right at all**, or do cameras want
   their own surface? A house with six cameras makes them a category, not room
   furniture — but that's a product-shape question, not a renderer one.
4. **Does the "LIVE" indicator (§3.2) match your instinct?** It's the one place I'm
   proposing to deviate from the established visual language.
