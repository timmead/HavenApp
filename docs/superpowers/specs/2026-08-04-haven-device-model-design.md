# A tile renders a device — design

**Date:** 2026-08-04
**Status:** written, awaiting review
**Sub-project:** 7a — the device model
**Followed by:** 7b (type selection in the `+` flow), 7c (the composite types themselves)

## What this is

Today a tile renders an **entity**. This makes it render a **device**: a type plus named inputs.

Most devices are one entity and are created automatically, so nothing about a light changes. The
point is the ones that are not: a garage door is a cover and two limit sensors; a shade group is a
master shade and its followers, presented as one tile that fans its actions out.

That is a model change rather than an extension because of what the inputs are, not because there is
no primary. 6a and 6b assume one primary plus companions **of its own physical device** — a shade
group's members are separate devices in separate registry entries, chosen by the household, and no
amount of widening companion *discovery* reaches them.

### A shade group has a master, and shows only its position

**One nominated shade supplies the group's state; the rest follow its commands.**

Reconciling several positions produces a number no shade is actually at: three shades at 40%, 60% and
100% average to 67%, which is a position none of them holds and which no action would produce. Min
and max are equally arbitrary — they answer "how open is the most open one", which is not the
question a tile asks.

The master's position is honest, predictable, and correct in the case that matters: after any group
action the members have all been sent the same command, so they converge on it.

**The cost, stated:** a follower moved on its own — by an automation, or by hand — is not reflected.
The tile shows the master until the group is next commanded. A tile that averaged would hide the same
divergence behind a number that looks precise, which is the worse of the two.

## The decision that makes this affordable

**A simple device's id is its entity id.**

Every stored setting today — display name, size, state style, surface membership, room order,
role bindings — keys on an entity id. If `light.kitchen` remains the id of the device that renders
`light.kitchen`, then every one of those records keeps working with no migration and no rewrite.

Only composites need new ids, and only composites are stored. A device is otherwise *implied* by its
entity existing.

The alternative — synthetic ids for everything — means migrating the whole document on first launch,
and a bug there costs a household its arrangement. This is the same instinct as `DashboardDocument`
merging rather than replacing: the stored record is somebody's home, and the safest change to it is
none.

## The model

```swift
/// What kind of thing a device is, and therefore what renders it.
public struct DeviceType: Sendable, Equatable, Identifiable {
    public let id: String                 // "light", "garage_door", "shade_group"
    public let name: String               // "Light", "Garage door", "Shade group"
    public let roles: [DeviceTypeRole]
}

public struct DeviceTypeRole: Sendable, Equatable {
    public let role: DeviceRole
    /// Which domains an entity must be in to fill this role.
    public let domains: [Domain]
    public let cardinality: Cardinality   // .one or .many
    /// A role a device cannot be without. A garage door needs its cover; its limits are optional.
    public let isRequired: Bool
}
```

`DeviceRole` gains cases as types need them — `primary`, `openLimit`, `closedLimit`, `follower`. It
already exists and already stores; this widens it.

**`primary` is `.one` and required on every type.** It is the entity a device's state is read from,
which is what makes `DeviceState.primary` survive this change unaltered: a shade group's primary is
its master, a garage door's is its cover, a light's is itself.

### The registry is a table

A static `DeviceTypes.all` in HavenCore, each entry deliberate and tested, the way
`DeviceCurationRule.defaultRules` is. A handful is the expectation; if it ever becomes dozens, the
thing that changes is how renderers are resolved, and that is noted rather than built for.

`DeviceTypes.candidates(for entityId:)` returns every type whose **required** roles that entity could
fill — which is what 7b's chooser offers, and what tells it to skip the step when there is one
answer.

### What is stored

Composites only:

```
devices.<deviceId> = {
    "type": "shade_group",
    "area": "living",
    "inputs": { "primary": ["cover.a"], "follower": ["cover.b", "cover.c"] }
}
```

Every role holds a list, including the `.one` roles, so that reading the document never has to switch
on cardinality — the *type* says how many are meaningful and a second entry in a `.one` role is
ignored rather than crashing something.

`deviceId` **is the primary's entity id**, which is the same rule a one-entity device follows — so
the app has exactly one id space and it is entity ids.

The first attempt generated `haven:…` ids, on the reasoning that deriving an id from the inputs would
orphan the device's name and size the moment somebody added a shade. That reasoning was right about
*inputs* and wrong about the *primary*: followers change, a primary does not. And the generated id
broke the thing it was protecting — every surface renders a ref by its primary, so a device stored
under any other key was looked up and never found. A garage door came back as a switch on the next
launch, and removing it wrote membership against an id the device was not stored under.

What this gives up is changing which entity is the primary. That would move the id and orphan the
settings — and a device with a different primary is a different device, which is why nothing offers
it.

Simple devices are absent from the document entirely.

### An entity used by a composite does not also render alone

A shade group and its three shades must not be four tiles. Any entity that is an input to a composite
**in the same room** is removed from that room's refs.

*In the same room*, because moving one shade to another area in Home Assistant should still give it a
tile there — the same precedence `RegistryResolver` and the curation rules already apply: HA's own
configuration outranks Haven's heuristics.

### Actions fan out

A shade group's tap has to reach the master **and** its followers — the master is where state is
read, not where commands stop. `BulkActionRunner` already does exactly this for a room's "Close all",
including counting the ones that did not respond, and a composite's action is the same job with a
different set. It is reused rather than reimplemented.

## What changes, concretely

- **`DeviceRef.composite(type:inputs:)`** becomes real, and `inputs` becomes `[String: [String]]` so
  a role can hold several entities. It has carried a `// abstraction only in D` comment since the
  first sub-project; this is what it was for.
- **`SectionBuilder`** reads stored composites for each area, emits them as refs, and removes their
  inputs from the room's entity refs.
- **`DeviceTileView`** dispatches on the device's *type* rather than on `Domain.of(entityId)`. Every
  existing renderer becomes the rendering of a 1:1 type, which is a rename of the switch and not a
  rewrite of any tile.
- **`CompositeState`** keeps its resolver, its vocabulary and its derived-face rules, and takes its
  inputs from the device rather than discovering companions by `deviceId`. **6a's discovery is not
  deleted** — it becomes how a 1:1 device finds context it was never explicitly given, which is still
  the only thing that works with no configuration at all.
- **`DeviceRole.roles(for domain:)`** is replaced by the roles on the type. That function shipped
  today; it was the right shape for one type and the wrong one for a registry.

## What does not change

Membership, order, sizes, names, styles and their storage. The dashboard document's schema stays at
1 — a `devices` key is an addition, and every build that cannot read it ignores it, which is the
discipline every other key in that document already follows.

## Testing

**HavenCore.** A simple device's id is its entity id, and resolving one requires no stored record.
`candidates(for:)` returns exactly the types whose required roles an entity can fill — one for a
light, more than one for a cover. A composite's inputs are removed from its room's refs, and are
*not* removed from a different room's. A stored composite with an input that no longer exists still
resolves, minus that input; one whose required role is empty does not resolve at all.

**App.** A room containing a shade group and its members renders one ref, not four. A group's
command reaches every member, and its displayed position is the master's — including when a follower
disagrees, which is the case the averaging alternative would have hidden.

**Rendered.** A room with a composite beside ordinary tiles.

## Out of scope

Type selection in the `+` flow (7b), every composite type beyond the garage door that already exists
(7c), and any change to how curation assigns tiers.
