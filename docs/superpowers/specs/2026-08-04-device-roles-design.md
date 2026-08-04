# Bound roles, and a state derived from them — design

**Date:** 2026-08-04
**Status:** approved, implementing
**Sub-project:** 6b — which entity plays which role, and what that lets Haven say
**Follows:** 6a, `CompositeState` (`06cc955`)

## What this is

A garage door reports *open* or *closed*. Two limit sensors report *fully open* and *fully closed*,
and between them describe a third state the cover entity cannot: **partly open**.

6a surfaced those sensors as readings beside the cover. This lets the household say which sensor is
which, and uses that to derive the cover's own state.

## Why binding rather than a heuristic

The alternative was matching entity names for "fully open" and "fully closed". Rejected, and not
narrowly: **a heuristic that misses fails silently.** No refinement happens, nothing says why, and
the user is left comparing their entity names against a rule they cannot see. Integrations name these
sensors every way there is.

Explicit binding is never wrong, works for every integration, and costs a picker the configuration
sheet is already shaped to hold.

The cost, stated: nothing happens until somebody configures it. A garage door shows 6a's readings and
its own two-state face until its limits are bound. That is a worse default than a heuristic that
works, and a better one than a heuristic that quietly does not.

## Roles

```swift
public enum DeviceRole: String, Sendable, Equatable, CaseIterable {
    case openLimit = "open_limit"
    case closedLimit = "closed_limit"
}
```

**Two, because two are needed.** A lock's door contact is a real role and would let Haven say
"locked, but the door is open" — it is not here, because that is a second derivation with its own
question about what the tile should then read, and inventing the storage for it now would be
designing against a device nobody has described.

`DeviceRole.roles(for:)` returns `[.openLimit, .closedLimit]` for `.cover` and nothing for every other
domain, so the configuration sheet shows a binding section only where one means something.

## Storage

`entities.<entityId>.bindings.<role>` = the companion's entity id, beside `sizes` and `state_style`.
Unreadable roles are dropped rather than defaulted, as everywhere else in this document.

Per entity rather than per surface: which sensor is the closed limit is a fact about the device, not
about the screen.

## The derived state

`DeviceState` gains a face:

```swift
public struct DeviceState: Sendable, Equatable {
    public let primary: String
    /// The device's state once its bound roles are read — **nil when nothing refines it**, so a
    /// surface falls back to the primary entity's own state and an unbound device is unchanged.
    public let face: TileState?
    public let readings: [DeviceReading]
}
```

### The cover rule

| closed limit | open limit | face |
|---|---|---|
| on | — | Closed |
| — | on | Open |
| off | off | **Partly open** |
| unreachable, or unbound | | nil — no refinement |

**Both limits off is the whole point.** It is the only combination the cover entity cannot express,
and the only reason to do any of this.

**Either limit unreachable yields nil**, not a guess. A door whose closed sensor is offline is a door
Haven does not know about, and "Partly open" asserted from one working sensor would be exactly the
confident wrong answer `TileState.unavailable` exists to avoid.

Both limits on is contradictory hardware; it resolves to **Closed**, because a garage reported shut
by its own closed sensor is the reading you act on.

### Bound entities leave the readings

An entity consumed by the face is not also listed beneath it. "Partly open" over "Fully Open — Off,
Fully Closed — Off" is the same fact three times, and the third one is the one people read.

## Rendering

`CoverTile` and `CoverModal` prefer `face` when present. Both already draw a `TileState`, so this is
a substitution rather than a new layout — **which is what 6a's design was for**: the tile reads a
value it does not compute.

The configuration sheet gains a **Sensors** card for covers: one row per role, each picking from the
device's companions or *None*, drafted and committed with everything else on Done.

## Testing

**HavenCore.** The truth table above, every row, including both-unreachable and one-unreachable.
Roles are offered for covers and no other domain. Storage round-trips and merges beside a name, a
size and a style; an unreadable role is dropped. A bound entity is absent from `readings`.

**App.** The binding writes in the same single frame as the rest of the sheet.

**Rendered.** A cover tile at each of the three derived states, and the sheet's Sensors card with a
role bound and unbound.

## Out of scope

A lock's door contact, roles for any other domain, and inline controls on a companion row.
