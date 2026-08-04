# A tile renders a device — design

**Date:** 2026-08-04
**Status:** written, awaiting review
**Sub-project:** 7a — the device model
**Followed by:** 7b (type selection in the `+` flow), 7c (the composite types themselves)

## What this is

Today a tile renders an **entity**. This makes it render a **device**: a type plus named inputs.

Most devices are one entity and are created automatically, so nothing about a light changes. The
point is the ones that are not: a garage door is a cover and two limit sensors; a shade group is
several covers with no primary at all, presented as one tile that fans its actions out.

That last shape is why this is a model change rather than an extension. 6a and 6b assume *one primary
entity plus companions of its own physical device*. A shade group has neither a primary nor a shared
device, and no amount of widening `DeviceState` reaches it.

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

`DeviceRole` gains cases as types need them — `primary`, `openLimit`, `closedLimit`, `member`. It
already exists and already stores; this widens it.

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
    "inputs": { "member": ["cover.a", "cover.b"], ... }
}
```

`deviceId` is generated once and never derived from the inputs. **Deriving it would orphan the
device's own name and size the moment somebody added a shade to the group** — the id would change and
every record keyed on it would point at nothing.

Simple devices are absent from the document entirely.

### An entity used by a composite does not also render alone

A shade group and its three shades must not be four tiles. Any entity that is an input to a composite
**in the same room** is removed from that room's refs.

*In the same room*, because moving one shade to another area in Home Assistant should still give it a
tile there — the same precedence `RegistryResolver` and the curation rules already apply: HA's own
configuration outranks Haven's heuristics.

### Actions fan out

A shade group's tap has to reach every member. `BulkActionRunner` already does exactly this for a
room's "Close all", including counting the ones that did not respond, and a composite's action is the
same job with a different set. It is reused rather than reimplemented.

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

**App.** A room containing a shade group and its members renders one ref, not four.

**Rendered.** A room with a composite beside ordinary tiles.

## Out of scope

Type selection in the `+` flow (7b), every composite type beyond the garage door that already exists
(7c), and any change to how curation assigns tiers.
