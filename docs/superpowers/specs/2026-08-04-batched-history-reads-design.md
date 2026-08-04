# Batching history reads — design

**Date:** 2026-08-04
**Status:** approved, implementing
**Follows:** the 2×1 sensor sparkline (`a30886c`)

## The problem

Every wide sensor tile fetches its own day of history on appear. Six sparklines on a dashboard is
six `history/history_during_period` commands, each with its own round trip, repeated every five
minutes as `HistoryRange.day.cacheLifetime` expires.

`HistoryCache` was built for modals — one chart, opened deliberately — and the sparkline turned it
into a per-tile cost paid on a screen the user only glances at.

## What makes this cheap

Two facts, both already true:

- **`history/history_during_period` takes `entity_ids` as an array.** `WSCommand.historyDuringPeriod`
  hardcodes `[entityId]`; the protocol never required that.
- **The response is keyed by entity id.** `HistoryParsing.fromHistory` reads
  `result.asObject?[entityId]`, so a multi-entity reply parses with the *existing* parser, once per
  entity, with no new parsing code and no new tests of the wire format.

So this is a coalescing layer, not a new protocol path.

## Decisions

### Coalesce on the next turn of the main actor, with no timer

A `load` that misses the cache joins a pending set and schedules a flush; the flush yields once,
letting every other request already enqueued on this turn join, then issues **one** command for the
whole set.

**No debounce**, which was the alternative. A 50ms window would catch tiles that appear a frame or
two apart, at the cost of 50ms added to every sparkline's first paint. Tiles in one grid lay out
together, so the turn-based batch gets the common case; the cost of missing is an extra request, not
a wrong picture.

Named honestly: **a room whose tiles appear across separate turns will make more than one request.**
That is the accepted cost of not adding a timer.

### Grouped by what a single request can express

One command carries one `start_time`, one `end_time` and one `no_attributes` flag, so the batch key
is `(range, attribute)`. Two sensors at `.day` with no attribute travel together; a modal's `.week`
does not join them.

### Statistics ranges are not batched

`recorder/statistics_during_period` also takes a list, but no sparkline uses it — `.day` is raw
history, and the longer ranges belong to modals opened one at a time. Batching a path with no
contention would be machinery with no purpose.

### One request, one failure

A batch that throws fails every entity in it, where six separate requests could fail
independently. In practice the failure is the connection, which fails all six anyway. The existing
rule holds unchanged: **a failure never touches the cache**, so a stale chart survives a failed
refresh and a later attempt retries.

### Call sites do not change

`HistoryCache.load(_:range:attribute:)` keeps its signature and its behaviour. Tiles and modals call
it exactly as they do now; the batching is inside. That is the whole point of putting it here rather
than asking each screen to declare its sensors — a view that forgot to prefetch would render a
sparkline-shaped blank.

## Architecture

### HavenCore

```swift
// WSCommand
static func historyDuringPeriod(id: Int, entityIds: [String], startISO: String,
                                endISO: String, includeAttributes: Bool = false) -> Data

// HomeConnection
func histories(entityIds: [String], attribute: String?, range: HistoryRange,
               now: Date) async throws -> [String: HistorySeries]
```

The single-entity `historyDuringPeriod` becomes a caller of the array form, so there is one place
that spells the command.

### App

`HistoryCache` gains:

- `pending: [BatchKey: Set<String>]` — entity ids waiting to go out, per group.
- `flushes: [BatchKey: Task<Void, Never>]` — the scheduled flush per group, so a second request
  joins the first rather than starting its own.

`inFlight` keeps its current meaning and its current key, so the existing "don't ask twice for the
same thing" guard is untouched.

## Testing

**HavenCore.** `historyDuringPeriod` emits every id in `entity_ids`; a multi-entity reply parses
into one series per entity, including the case where one requested entity is absent from the reply
(recorder excludes it) and must come back empty rather than missing.

**App.** The one that matters: **three tiles asking on the same turn produce one
`history/history_during_period` frame, not three** — counted on the socket, exactly as
`aNameAndASizeCommitInOneWrite` counts config writes, and for the same reason: the resulting cache is
identical either way, so only the frames can tell the two apart. Plus: a cached entity is not
re-requested, and a failure leaves a stale entry in place.

## Out of scope

Prefetching for tiles that have not appeared, batching across ranges, statistics batching, and any
change to how often a sparkline refreshes — the five-minute lifetime stays as it is.
