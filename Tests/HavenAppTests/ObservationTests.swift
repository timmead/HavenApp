import Testing
import Foundation
import Observation
import HavenCore
@testable import HavenApp

/// **Does the screen actually redraw?**
///
/// This suite exists because of a gap named in the architecture review: splitting an `@Observable`
/// apart changes *observation granularity*, and when that breaks, the failure is a view that
/// silently stops updating. Nothing else here catches it — no test renders a view, and a SwiftUI
/// preview is worse than useless for it, since a preview holds a fixed store and looks pixel-perfect
/// while observation is completely dead.
///
/// `withObservationTracking` is the mechanism. It records exactly what SwiftUI records when it
/// evaluates a `body`: the set of `@Observable` properties actually read. If mutating the store
/// does not fire the change handler, then a `body` that read the same things would not be
/// re-evaluated either — which *is* the bug, expressed the only way a test can express it.
///
/// These are written against the accessors the views really use, not against stored properties
/// directly, so a refactor that moves storage behind a computed property or a child object has to
/// keep the observation working or these go red.
@Suite @MainActor struct ObservationTests {
    /// Records whether reading `read` and then performing `mutate` produces an observation event.
    ///
    /// `onChange` fires *before* the value changes (it is a will-set notification), synchronously,
    /// on the mutating thread — so by the time `mutate` returns, the flag is already accurate and
    /// there is nothing to wait for. That is also why `read` must genuinely touch the property:
    /// a closure that returns a constant registers no dependencies and would report `false`
    /// forever, which is why every test below asserts a `true` case rather than only a `false` one.
    private func observes(_ read: () -> Void, whenMutating mutate: () -> Void) -> Bool {
        // A reference box rather than a captured `var`: `onChange` is `@Sendable`, since the
        // notification can in principle arrive from whichever thread performed the mutation.
        // Everything here is `@MainActor` and the callback is synchronous, so there is no actual
        // race — this is the type system asking to be told that, not a concurrency problem.
        final class Box: @unchecked Sendable { var fired = false }
        let box = Box()
        withObservationTracking { read() } onChange: { box.fired = true }
        mutate()
        return box.fired
    }

    private func entity(_ id: String, _ state: String) -> EntityState {
        EntityState(entityId: id, state: state, attributes: [:], lastUpdated: Date(timeIntervalSince1970: 0))
    }

    /// The single most important one: a tile reads `state(_:)`, and a WebSocket push writes
    /// `states`. Every tile in the app is dead if this stops holding.
    @Test func aTileReadingStateSeesAStatePush() {
        let store = HomeStore()
        store.states["light.a"] = entity("light.a", "off")

        #expect(observes({ _ = store.state("light.a") },
                         whenMutating: { store.states["light.a"] = self.entity("light.a", "on") }))
    }

    /// `isOn` is the other read path into `states`, used by the roll-up rows.
    @Test func aRollupReadingIsOnSeesAStatePush() {
        let store = HomeStore()
        store.states["light.a"] = entity("light.a", "off")

        #expect(observes({ _ = store.isOn("light.a") },
                         whenMutating: { store.states["light.a"] = self.entity("light.a", "on") }))
    }

    /// The bulk-action failure count is read through a *method*, not a stored property, and its
    /// backing store is private. That indirection is exactly what a careless extraction breaks:
    /// move `bulkFailures` behind a non-`@Observable` holder and this method keeps returning the
    /// right number while no view ever re-reads it.
    @Test func aRollupRowReadingItsFailureCountSeesTheCountChange() {
        let store = HomeStore()

        #expect(observes({ _ = store.bulkFailureCount(for: .lights, in: "kitchen") },
                         whenMutating: { store.recordBulkFailures(2, for: .lights, in: "kitchen") }))
    }

    /// The dashboard reads `rooms()`, which is derived from `home` — rebuilt wholesale on every
    /// registry reload.
    @Test func theDashboardReadingRoomsSeesAStructureReload() {
        let store = HomeStore()

        #expect(observes({ _ = store.rooms() },
                         whenMutating: {
                             store.home = ResolvedHome(floors: [
                                 ResolvedFloor(id: "f1", name: "Ground", level: 0, areas: [])
                             ])
                         }))
    }

    /// The modal sheet binding reads `Navigation.presented`, which a tile writes on tap or
    /// long-press. If this stops observing, tapping a tile opens nothing at all — and it would
    /// still pass every other test in this repository.
    @Test func theSheetBindingSeesAPresentationRequest() {
        let navigation = Navigation()

        #expect(observes({ _ = navigation.presented },
                         whenMutating: { navigation.presented = .control(entityId: "light.a") }))
    }

    /// The history chart reads through `history(_:_:attribute:)`, whose cache is a stored
    /// dictionary keyed by a computed string.
    @Test func aChartReadingHistorySeesAFetchLand() {
        let store = HomeStore()
        let key = HomeStore.historyKey("sensor.a", .day, nil)

        #expect(observes({ _ = store.history("sensor.a", .day) },
                         whenMutating: {
                             store.historyCache.byKey[key] = (HistorySeries(points: []), Date())
                         }))
    }

    /// The room pills read `environment`, which is a computed property forwarding to
    /// `EnvironmentCoordinator.byArea` — two levels of indirection between the view and the
    /// storage, and each is a place observation can be dropped.
    ///
    /// `resolveEnvironment()` is what a structure reload calls, so this is the real path: the
    /// pills must repaint when the nominations are recomputed.
    @Test func theRoomPillsSeeNominationsResolve() {
        let store = HomeStore()
        store.states["sensor.t"] = EntityState(
            entityId: "sensor.t", state: "21",
            attributes: ["device_class": .string("temperature"),
                         "unit_of_measurement": .string("°C")],
            lastUpdated: Date(timeIntervalSince1970: 0))
        store.home = ResolvedHome(floors: [
            ResolvedFloor(id: "f1", name: "Ground", level: 0, areas: [
                ResolvedArea(id: "living", name: "Living", entityIds: ["sensor.t"],
                             temperatureEntityId: nil, humidityEntityId: nil, tiers: [:])
            ])
        ])

        #expect(observes({ _ = store.environment },
                         whenMutating: { store.resolveEnvironment() }))
    }

    /// The subsection sheets read `store.subsections(_:on:)`, which joins the resolver to
    /// `config.document` exactly as `device(_:)` joins `deviceRef(for:)` — see the comment beside it
    /// in `HomeStore.swift`. If that join ever reads a document that isn't `config.document` itself
    /// (a captured copy, a snapshot taken at some other time), a subsection's size or mode changing
    /// would stop repainting it, silently.
    @Test func aSubsectionReadSeesADocumentWrite() {
        let store = HomeStore()
        store.home = ResolvedHome(floors: [
            ResolvedFloor(id: "f1", name: "Ground", level: 0, areas: [
                ResolvedArea(id: "living", name: "Living", entityIds: ["light.a"])
            ])
        ])
        let room = store.rooms().first { $0.id == "living" }!

        #expect(observes({ _ = store.subsections(room, on: .overview) },
                         whenMutating: {
                             store.config.seedForTesting(DashboardDocument().settingDisplayMode(.wrap))
                         }))
    }

    /// **The negative control.** Without it, every test above could be passing because the harness
    /// reports `true` unconditionally rather than because observation works. Reading `states` and
    /// mutating `home` — two genuinely separate properties — must not fire.
    @Test func readingOnePropertyDoesNotObserveAnUnrelatedOne() {
        let store = HomeStore()
        store.states["light.a"] = entity("light.a", "off")

        #expect(!observes({ _ = store.state("light.a") },
                          whenMutating: {
                              store.home = ResolvedHome(floors: [
                                  ResolvedFloor(id: "f1", name: "Ground", level: 0, areas: [])
                              ])
                          }),
                "reading one property must not register a dependency on an unrelated one")
    }

    /// **Granularity is per-property, not per-key — worth knowing, and not what you might assume.**
    ///
    /// `states` is one dictionary, so reading *any* entity out of it registers a dependency on the
    /// whole thing, and a push for *any* other entity invalidates that read. On a forty-tile floor
    /// every push therefore re-evaluates every tile's `body`.
    ///
    /// That is fine today — a `body` is cheap, and SwiftUI still diffs the result before touching
    /// the render tree — and it is pinned here rather than left as folklore because the obvious
    /// "optimisation" of splitting `states` into per-entity observables would be a large change
    /// justified by an assumption nobody had checked. This is the check. Written the other way
    /// round first, and it failed, which is how the assumption got noticed at all.
    @Test func readingOneEntityObservesEveryOtherEntityToo() {
        let store = HomeStore()
        store.states["light.a"] = entity("light.a", "off")
        store.states["light.b"] = entity("light.b", "off")

        #expect(observes({ _ = store.state("light.a") },
                         whenMutating: { store.states["light.b"] = self.entity("light.b", "on") }),
                "one dictionary means one dependency; if this ever stops holding, the tiles got finer-grained")
    }
}
