# Composite device state — design

**Date:** 2026-08-04
**Status:** approved, ready for an implementation plan
**Sub-project:** 6a — a device's state as the compound of its entities

## What this is

A device's state is often not one entity's state. A lock says *locked*; whether the door is actually
shut is a different entity. A garage actuator says *open*; whether it is **fully** open is a sensor.
Home Assistant models these as separate entities of one device, and Haven currently renders the
actuator and silently drops the rest.

This resolves a device's entities into **one value describing that device's state**, which any
surface reads. The modal is the first consumer. The tile is the second.

## The requirement that shapes everything

**The composite is not a modal feature.** A device's state being a compound of several entities is a
fact about the device, so the combining happens once, in HavenCore, and produces a value. A modal
renders all of it; a tile renders the part that fits. Neither computes it.

Had this been built as "a section in the modal", hoisting it to the tile would have meant writing the
combination a second time — and two implementations of "is this door actually shut" is exactly the
class of disagreement `TileState` was created to end.

## Scope

**6a (this spec):** the resolved value, and the modal reading it.
**6b (later):** the tile reading it, and explicit user binding — which entity plays which role.

6a discovers companions automatically. 6b lets the household correct that. Discovery first, because
what a real device's entity set looks like is the input the binding design needs, and guessing it
now would be designing a picker for a shape nobody has seen.

## What is a companion

An entity is a companion of a primary when both carry the same registry `deviceId` and the entity's
curation tier is `.companion`.

Both halves already exist. `EntityCuration`'s `container(domain:)` rule is what produces
`.companion`: a device with a `.primary` camera demotes its `.primary` entities in *other* domains.
`ResolvedHome.registryInfo[entityId]?.deviceId` is the grouping. **No new configuration and no new
registry work** — this reads what curation already decided and has had nowhere to put.

That tier is currently rendered by no surface at all, which the curation spec accepted deliberately
and named the fix for: *"the eventual home for these is inside the parent's own modal."* This is that
fix, generalised so it is not only the modal.

**An entity that moved rooms is not a companion.** Moving one to another area in Home Assistant makes
it `.primary` there — a tile of its own — so the tier filter excludes it without a special case. HA
configuration outranking the heuristic, exactly as `RegistryResolver` already has it.

## The value

```swift
/// One device's state, as the compound of its entities.
public struct DeviceState: Sendable, Equatable {
    /// The entity a surface is rendering — the one with the controls.
    public let primary: String
    /// Supporting readings, **most contextually important first**.
    public let readings: [DeviceReading]
}

public struct DeviceReading: Sendable, Equatable {
    public let entityId: String
    /// What this reading is *of* — "Door", "Position", "Motion".
    public let label: String
    /// What it currently says — "Closed", "Fully open", "Detected".
    public let value: String
    /// Whether it is in its notable state, for tint. Nil where the notion does not apply.
    public let isActive: Bool?
}

public enum CompositeState {
    public static func resolve(primary: String, deviceId: String?,
                               registry: [String: EntityRegistryInfo],
                               tiers: [String: CurationTier],
                               states: [String: EntityState]) -> DeviceState
}
```

### Ordering is part of the contract, not a rendering choice

`readings` is ordered so that **a tile showing only the first shows the right one**. That decision
belongs here rather than in a tile, because it is the same decision on every surface and because a
tile choosing for itself is how two surfaces come to disagree.

The order: binary sensors that contradict or qualify the primary's own state first (a door sensor
beside a lock), then other binary sensors, then numeric sensors, then everything else. Within a
group, by entity id, so a home renders identically on every launch.

### Words come from `TileState`

A companion binary sensor's value is `TileState.binarySensor(deviceClass:isActive:)`'s `word` — the
vocabulary that already knows a door is *Open*, a smoke detector has *Detected*, a moisture sensor is
*Wet*. Building a second vocabulary for the same states is how "Open" and "Opened" end up on one
screen.

The `label` is the companion's own display name through `DisplayName`, so a renamed entity reads that
way here too.

### Unreachable is a reading, not an absence

A companion Haven cannot reach reads `TileState.unavailable.word`. Dropping it would make an
unreachable door sensor and an absent one look identical, and the whole point of the feature is
telling the user what the device actually knows.

## Rendering, 6a

`DeviceModalView` gains one section beneath the domain modal — **there, not inside each of the eleven
modals**, so a device gains context by being a device rather than by someone remembering to add it.

A row per reading: label, value, and the value tinted when `isActive`. Read-only in this revision:
tapping does nothing and no control is offered. A companion with its own controls is reachable as its
own tile today by adding it with the `+`, and inline actuation is 6b's question, not this one's.

The section renders nothing at all when there are no readings, so every device without companions is
exactly as it is now.

## What 6b inherits

- **The tile** reads `readings.first` for its second line. No new resolution, no new vocabulary — the
  ordering contract above is what makes that line correct without the tile deciding anything.
- **Binding** replaces automatic discovery with a stored map of role to entity, and `resolve` grows a
  parameter. Every caller keeps reading `DeviceState`.
- **A refined face.** A garage whose actuator says *open* and whose sensor says *fully open* could
  render one state rather than a state plus a footnote. That needs a per-device-type rule table, and
  `DeviceState` is the value it would live on — deliberately not built now, because the rules should
  be written against devices that have been seen rather than imagined.

## Testing

**HavenCore.** Companion discovery: same device and `.companion` is in; same device but `.primary`
is out; another device is out; the primary itself is never its own companion. Ordering: a door sensor
precedes a battery level; ties break on entity id. Words come from `TileState` — a `door` companion
reads *Open*, not *On*. An unreachable companion reads *Unavailable* rather than vanishing.

**App.** A store-level test that a lock with a door sensor on the same device resolves to one reading,
and that the same lock in a home with no registry information resolves to none.

**Rendered.** A modal with no companions (unchanged from today), one with a single reading, and one
with several including an unreachable one.

## Out of scope

Inline controls on a companion row, user binding, tile rendering, refining the primary's own state
word, and any change to which tier curation assigns — this spec reads curation's output and never
argues with it.
