import SwiftUI
import HavenCore

/// Fetched history, and the recent state-change lists that sit beside it.
///
/// The second seam out of `HomeStore`. Like `BulkActionRunner` it is a job with its own state and
/// no interest in the rest of the store: it needs a connection to ask down, and nothing else — not
/// `states`, not the registry, not the dashboard document.
///
/// **`@Observable`, and load-bearing.** `SensorModal` and `RoomEnvironmentHistoryView` read
/// `history(...)` and `stateChanges(...)` inside their bodies, so these caches must stay observable
/// *through* `HomeStore`'s reference to this object or a chart never appears when its fetch lands.
/// `ObservationTests.aChartReadingHistorySeesAFetchLand` is what holds that true across this move.
@MainActor @Observable
final class HistoryCache {
    /// Fetched series, with the moment each was fetched — see `HistoryRange.cacheLifetime`.
    var byKey: [String: (series: HistorySeries, fetched: Date)] = [:]

    /// Keys with a fetch currently in flight.
    ///
    /// This does *not* protect against flicking across the range picker — every range is a
    /// different cache key (see `key(_:_:_:)`), so two different ranges never collide here at all;
    /// each just gets its own in-flight entry. What this actually guards against is `.task(id:
    /// range)` (`SensorModal`, `RoomEnvironmentHistoryView`) restarting on the *same* key: flicking
    /// Day → Week → Day cancels the first Day task but — per `HAWebSocketClient.request` being a
    /// bare continuation with no cancellation handling (see `CameraPlaybackPlan`'s doc for the same
    /// fact) — does not cancel its in-flight `history` command. Without this guard the second Day
    /// task would fire a duplicate request for a key whose answer is already on the way; with it,
    /// the second task finds the key already in flight and returns immediately, and the first
    /// request's result lands in `byKey` for both to read.
    private var inFlight: Set<String> = []

    /// What a single request can express: one `start_time`, one `end_time`, one `no_attributes`.
    /// Two `.day` reads with no attribute travel together; a modal's `.week` does not join them.
    private struct BatchKey: Hashable {
        let range: HistoryRange
        let attribute: String?
    }

    /// Entity ids waiting to go out, per group.
    private var pending: [BatchKey: Set<String>] = [:]
    /// The scheduled flush per group, so the second request of a turn joins the first rather than
    /// starting its own.
    private var flushes: [BatchKey: Task<Void, Never>] = [:]

    /// Recent state changes per entity, with the moment each was fetched — see
    /// `HistoryRange.day.cacheLifetime`, the same lifetime `byKey` uses. Keyed by entity id alone —
    /// unlike `byKey` there is one range (Day) and no attribute variant to disambiguate.
    ///
    /// Before this carried a `fetched` date, an entry never expired: open a door sensor's modal at
    /// 09:00 and again at 18:00 and the header (read live off `states`) said "Active" while this
    /// list still ended at 08:12's "Off" — the modal contradicting itself for the whole session.
    var stateChangesByEntity: [String: (changes: [StateChange], fetched: Date)] = [:]

    /// Entity ids whose most recent `loadStateChanges` attempt threw. Inserted unconditionally on
    /// failure — including for an id with a stale cached list already sitting in
    /// `stateChangesByEntity`, since `loadStateChanges` never touches the cache on error — so this
    /// set is *not* itself "ids with no cached entry of any age"; that framing only holds for the
    /// callers that consult it, because `stateChangesLoadFailed` is only ever checked once
    /// `stateChanges(_:)` has already returned `nil`. See `loadStateChanges`: a failure never
    /// touches the cache, so a stale list survives a failed refresh exactly like `byKey` does —
    /// this exists to tell "never asked" apart from "asked and it failed" for an entity with
    /// nothing cached to show.
    var stateChangesFailed: Set<String> = []

    /// The live connection to ask down, or `nil` between sessions. Set by `HomeStore.attach`, so
    /// this object never has to know when a session begins or ends.
    private var connection: HomeConnection?

    func attach(_ connection: HomeConnection?) { self.connection = connection }

    func reset() {
        connection = nil
        byKey = [:]
        inFlight = []
        pending = [:]
        // Cancelling rather than dropping: a flush awaiting a reply that will never come would hold
        // its callers forever.
        for (_, task) in flushes { task.cancel() }
        flushes = [:]
        stateChangesByEntity = [:]
        stateChangesFailed = []
    }

    /// The cache key for one series.
    ///
    /// `attribute` is part of it because a thermostat-only room reads two series off a single
    /// entity at a single range — `current_temperature` and `current_humidity`. Keyed on entity
    /// and range alone those collide, and the room's chart plots one series twice under two
    /// labels, which looks like data rather than like a bug.
    static func key(_ entityId: String, _ range: HistoryRange, _ attribute: String?) -> String {
        "\(entityId)#\(attribute ?? "")#\(range)"
    }

    /// Cached read for a previously-loaded history series. `nil` means "not loaded yet"
    /// (or the load failed) — callers should render an empty/loading state, not crash.
    func series(_ entityId: String, _ range: HistoryRange, attribute: String? = nil) -> HistorySeries? {
        byKey[Self.key(entityId, range, attribute)]?.series
    }

    /// Fetches and caches a history series for `entityId`/`range`/`attribute`. Reuses the cache
    /// while the entry is still within `range.cacheLifetime` (a range or attribute switch always
    /// misses, since the key changes); never caches a failure, so a transient error doesn't
    /// permanently block a later retry.
    /// Fetches and caches a history series for `entityId`/`range`/`attribute`. Reuses the cache
    /// while the entry is still within `range.cacheLifetime` (a range or attribute switch always
    /// misses, since the key changes); never caches a failure, so a transient error doesn't
    /// permanently block a later retry.
    ///
    /// **Requests made on the same turn of the main actor go out as one command.** A dashboard of
    /// wide sensors was six round trips for one glance — see `flush(_:)`. The signature and the
    /// behaviour a caller sees are unchanged: this is deliberately inside the cache rather than
    /// something each screen has to remember to do, because a view that forgot would render a
    /// sparkline-shaped blank.
    func load(_ entityId: String, range: HistoryRange, attribute: String? = nil) async {
        let key = Self.key(entityId, range, attribute)
        if let cached = byKey[key], Date().timeIntervalSince(cached.fetched) < range.cacheLifetime {
            return
        }
        guard !inFlight.contains(key), connection != nil else { return }
        inFlight.insert(key)
        let batch = BatchKey(range: range, attribute: attribute)
        pending[batch, default: []].insert(entityId)
        let task = flushes[batch] ?? {
            let scheduled = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.flush(batch)
            }
            flushes[batch] = scheduled
            return scheduled
        }()
        await task.value
    }

    /// Sends one request for everything that asked this turn.
    ///
    /// **The `yield` is the whole mechanism.** Each tile's `.task` is its own job on the main actor,
    /// so the first one to miss the cache schedules this and the rest are still queued behind it.
    /// Yielding once lets every one of them run, add itself to `pending`, and find this flush
    /// already scheduled — so a room's sparklines leave as a single command.
    ///
    /// A timer would catch more: tiles appearing a frame apart still form separate batches. That was
    /// weighed and declined — a debounce would add its delay to *every* sparkline's first paint, and
    /// the cost of missing here is one extra request rather than a wrong picture.
    private func flush(_ batch: BatchKey) async {
        await Task.yield()
        let ids = pending.removeValue(forKey: batch) ?? []
        flushes[batch] = nil
        guard !ids.isEmpty, let connection else {
            for id in ids { inFlight.remove(Self.key(id, batch.range, batch.attribute)) }
            return
        }
        let now = Date()
        defer {
            for id in ids { inFlight.remove(Self.key(id, batch.range, batch.attribute)) }
        }
        do {
            let series = try await connection.histories(entityIds: Array(ids).sorted(),
                                                        attribute: batch.attribute,
                                                        range: batch.range, now: now)
            for (id, one) in series {
                byKey[Self.key(id, batch.range, batch.attribute)] = (one, now)
            }
        } catch {
            // Leave the cache untouched so a later attempt can retry — and note that a *stale*
            // entry deliberately survives a failed refresh. An old chart beats a blank one.
            //
            // One request failing fails everything in it, where separate requests could have failed
            // independently. In practice the failure is the connection, which would have failed all
            // of them anyway.
        }
    }

    /// Cached recent state changes, ignoring `fetched` age — a stale list beats a blank one, exactly
    /// as `series(_:_:attribute:)` reads `byKey`. `nil` means "not loaded yet, or every attempt so
    /// far has failed"; callers distinguish the two with `loadFailed(_:)`.
    func stateChanges(_ entityId: String) -> [StateChange]? { stateChangesByEntity[entityId]?.changes }

    /// Whether the most recent fetch for `entityId` failed with nothing cached to fall back to. The
    /// binary-sensor modal uses this to tell "not asked yet" (render nothing conclusive, a loading
    /// state is fine) apart from "asked, and it failed" (say so, rather than show "Loading…"
    /// forever — the state before this existed, on an install without the `history` integration or
    /// an entity `recorder` excludes).
    func loadFailed(_ entityId: String) -> Bool { stateChangesFailed.contains(entityId) }

    /// Fetches and caches recent state changes. Reuses the cache while the entry is still within
    /// `HistoryRange.day.cacheLifetime` — the same lifetime and reasoning as `load`'s Day range,
    /// since this is always a Day query. Never caches a failure (so a transient error doesn't
    /// permanently block a retry) and never *clears* a stale cache on failure either — an old list
    /// beats a blank one.
    ///
    /// **`force` exists for callers that know the cache is wrong**, and there is exactly one class
    /// of them: a caller watching the entity's *live* state, which has just seen it change. The
    /// camera modal's event chips read the last activation out of this list to say "24m ago", and
    /// a five-minute-old list says that with total confidence about a sensor that fired thirty
    /// seconds ago. The push that moved the sensor is the proof the list is stale, so the chip
    /// re-asks on it. Being a parameter rather than a separate entry point keeps the caching in
    /// one place; being opt-in keeps every other caller on the cheap path.
    func loadStateChanges(_ entityId: String, force: Bool = false) async {
        let now = Date()
        if !force, let cached = stateChangesByEntity[entityId],
           now.timeIntervalSince(cached.fetched) < HistoryRange.day.cacheLifetime {
            return
        }
        guard let connection else { return }
        do {
            let changes = try await connection.stateChanges(entityId: entityId, range: .day, now: now)
            stateChangesByEntity[entityId] = (changes, now)
            stateChangesFailed.remove(entityId)
        } catch {
            // Leave the cache untouched so a later attempt can retry, but note the failure so a
            // caller with nothing cached can say so instead of showing "Loading…" forever.
            stateChangesFailed.insert(entityId)
        }
    }
}
