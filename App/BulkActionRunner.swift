import SwiftUI
import HavenCore

/// Runs a room's bulk action in bounded batches and remembers how much of it refused.
///
/// Split out of `HomeStore` because it is a self-contained job with its own state: it needs no
/// entity states, no connection, and no history — only a list of ids and something to do to each.
/// What it leaves behind in `HomeStore` is the part that genuinely belongs there, the optimistic
/// flips over `states`.
///
/// **`@Observable`, and that is load-bearing.** `bulkFailureCount` is read from inside
/// `RoomSectionView`/`RoomDetailView`'s `body`, so the tally has to be observable *through*
/// `HomeStore`'s reference to this object or those rows stop redrawing when a bulk action fails —
/// a failure no test that renders nothing could see. `ObservationTests` pins exactly that read.
@MainActor @Observable
final class BulkActionRunner {
    /// Identifies one room's roll-up of one kind. `Rollup.Kind` alone is not enough:
    /// `RoomSectionView`/`RoomDetailView` render one roll-up row *per room*, and a kind-only key
    /// would make a failure in the Kitchen's lights show up on the Living Room's lights row too —
    /// worse than the silent rollback this feature replaced, because it is affirmatively false
    /// about a room nobody touched.
    private struct Key: Hashable { let areaId: String; let kind: Rollup.Kind }

    /// How many entities the last bulk action of each room+kind failed to change.
    private var failures: [Key: Int] = [:]

    /// At most this many commands in flight during one bulk action. A forty-light room otherwise
    /// opens forty concurrent WebSocket requests, which is both rude to Home Assistant and a good
    /// way to have several of them time out and *become* the failures this surfaces.
    static let concurrency = 6

    func failureCount(for kind: Rollup.Kind, in areaId: String) -> Int {
        failures[Key(areaId: areaId, kind: kind)] ?? 0
    }

    /// Records the outcome of a bulk action. Always called, including with zero — a successful run
    /// has to clear the previous run's complaint, or the row goes on accusing the user of a
    /// failure they have already fixed.
    func record(_ count: Int, for kind: Rollup.Kind, in areaId: String) {
        failures[Key(areaId: areaId, kind: kind)] = count > 0 ? count : nil
    }

    func reset() { failures = [:] }

    /// Runs `work` over `targets` in bounded batches, then records how many threw against this
    /// room's roll-up of `kind`.
    ///
    /// The optimistic flip is **not** done here — the caller does it synchronously, before this is
    /// ever called. `work` only runs inside a batch's child tasks, so a flip placed there would
    /// wait on *earlier batches' network round-trips* rather than on nothing: a 40-light room would
    /// staircase its tiles off in visible blocks of six over a couple of seconds instead of the
    /// whole grid snapping off the instant the button is tapped, which defeats the entire point of
    /// optimistic state. Bounding the network must not also bound the UI.
    ///
    /// Each entity keeps its own rollback, done by `work` — conditionally, and only if the entity
    /// still holds the whole `EntityState` the flip wrote. One failure never disturbs another
    /// entity; that property predates this and must survive it.
    ///
    /// **The isolation here is fiddly and was arrived at by compiling, not by reasoning.** Two
    /// shapes that look obviously right do not build under `SWIFT_STRICT_CONCURRENCY: complete`:
    ///
    /// - A `@Sendable` closure cannot touch `states`, which is `@MainActor` — so `work` is
    ///   `@MainActor`, and only the `await` inside it actually suspends. That is enough: MainActor
    ///   tasks interleave at suspension points, so the network round-trips still overlap.
    /// - `withTaskGroup` + `group.addTask { @MainActor in … }` fails with *"pattern that the
    ///   region-based isolation checker does not understand how to check. Please file a bug"* —
    ///   a compiler limitation, not a mistake in the code. Plain child `Task`s collected into an
    ///   array avoid it entirely and read more simply.
    ///
    /// Do not "tidy" this back into a task group.
    func run(_ targets: [String], kind: Rollup.Kind, in areaId: String,
             _ work: @escaping @MainActor (String) async throws -> Void) {
        record(0, for: kind, in: areaId)
        Task { @MainActor in
            var failed = 0
            var index = 0
            while index < targets.count {
                let slice = Array(targets[index..<min(index + Self.concurrency, targets.count)])
                index += slice.count
                let running = slice.map { id in
                    Task { @MainActor in
                        do { try await work(id); return true } catch { return false }
                    }
                }
                for task in running {
                    if await task.value == false { failed += 1 }
                }
            }
            record(failed, for: kind, in: areaId)
        }
    }
}
