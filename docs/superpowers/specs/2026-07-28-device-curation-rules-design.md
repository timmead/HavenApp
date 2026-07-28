# Device curation rules — design

**Status:** implemented, `feat/device-curation-rules`.

## The problem

A UniFi Protect doorbell arrives from Home Assistant as **one device** exposing three entities:

| Entity | Domain | Was |
|---|---|---|
| `camera.front_doorbell` | `camera` | `.primary` |
| `media_player.front_doorbell_speaker` | `media_player` | `.primary` |
| `button.front_doorbell_chime` | `button` | `.primary` |

All three domains are in `EntityCuration.primaryDomains`, so all three earned an overview tile and
the room showed a "camera speaker" as though it were a device you own. It is not a device — it is
part of the doorbell.

The general statement: **curation looked at entities one at a time, and never at the device they
belong to.**

## Why a rule table rather than a heuristic

The obvious rule — one tile per device — is wrong, and a three-gang wall switch is why. That is one
device with `switch.gang1/2/3`, and all three are things you press. Any rule that demotes
same-domain siblings takes two of them away.

Home Assistant integrations model devices however they please, and no single rule describes all of
them. So this ships a **table of rules to be grown from observation**, not a theory of what a device
is. Each row is one line plus a test.

## The rules

```swift
public enum DeviceCurationRule: Sendable, Equatable, Hashable {
    case container(domain: String)
    case singlePrimary(platform: String, preferring: [String])
}

public static let defaultRules: [DeviceCurationRule] = [
    .container(domain: "camera"),
]
```

**`container(domain:)`** — a domain that defines what a device *is*. When a device has a `.primary`
entity in that domain, its `.primary` entities in **other** domains drop to `.companion`.
Same-domain siblings are untouched, which is what keeps the three-gang switch at three tiles.

**`singlePrimary(platform:preferring:)`** — for an integration that exposes one physical thing as
several unrelated controls. Only the highest-ranked entity survives; ties break on lowest entity id
so the same home renders identically on every launch.

**`singlePrimary` ships with no rows.** It exists because the shape is foreseeable, not because a
device has been observed needing it. That is stated here rather than disguised as justified.

## The safety property

Rules may only ever **demote**, and only from `.primary` to `.companion`. They never promote, never
touch `.hidden` — what the user hid in Home Assistant outranks every heuristic here — and never
touch `.secondary`, which is already off the overview grid.

The one direction that could cost someone a control they can reach today is the one direction none
of this takes. `rulesNeverRaiseATier` compares the full tier map with and without rules and holds
every entity to it.

## Where it runs

Three ordered passes in `EntityCuration.tiers(for:rules:)`:

1. Per-entity `tier(of:)` — unchanged
2. **Device rules** — demote only
3. Never-empty-a-room rescue — unchanged

The ordering is the design. **After** the per-entity pass, because a rule needs to know what each
entity would have been on its own. **Before** the rescue, because a room these rules empty must
still be rescued rather than rendering blank — the shape that gets there is a room holding only a
doorbell's speaker and chime.

## Two deliberate decisions

**A container that isn't showing demotes nothing.** If `camera.doorbell` is hidden in Home
Assistant, the rule goes inert. Hiding one entity of a device should not silently take the rest of
it away as well.

**Grouping is by `deviceId`, within an area.** An entity carrying its own `areaId` is resolved into
that area by `RegistryResolver`, so deliberately moving a camera's speaker to another room in Home
Assistant leaves it a tile there. That is HA configuration outranking our heuristic — the same order
of authority `tier(of:)` already applies to `hidden_by`.

## Where a demoted entity goes

`.companion`, which **no surface renders today**. The speaker disappears until device-grouped UI
exists.

This was chosen over `.secondary` (room detail, one tap away) with the trade-off stated: a wrong
rule makes a control unreachable rather than costing a tap. The mitigations are that rules are
added deliberately one row at a time, each with a test, and that the never-empty-a-room rescue
treats `.companion` as a rung — so a room cannot go blank because of this.

The eventual home for these is inside the parent's own modal, extending what `CameraEvents` already
does for a camera's binary sensors. That is a renderer change per parent domain and is not part of
this work.

## Testing

`DeviceCurationRuleTests` drives the rule *kinds* with injected rules, so the tests do not depend on
which rows happen to ship. `RegistryResolverTests` pins the reported symptom end to end — the
doorbell's speaker and chime off the grid, and a Sonos that merely shares a room with a camera
keeping its tile.

Verified by mutation: disabling the rule pass turns six tests red across both levels.

HavenCore 642 → 655 tests.
