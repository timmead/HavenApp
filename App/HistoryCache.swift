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
    func load(_ entityId: String, range: HistoryRange, attribute: String? = nil) async {
        let key = Self.key(entityId, range, attribute)
        let now = Date()
        if let cached = byKey[key], now.timeIntervalSince(cached.fetched) < range.cacheLifetime {
            return
        }
        guard !inFlight.contains(key), let connection else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        do {
            let series = try await connection.history(entityId: entityId, attribute: attribute,
                                                      range: range, now: now)
            byKey[key] = (series, now)
        } catch {
            // Leave the cache untouched so a later attempt can retry — and note that a *stale*
            // entry deliberately survives a failed refresh. An old chart beats a blank one.
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
