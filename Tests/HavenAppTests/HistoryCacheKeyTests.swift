import Testing
import Foundation
import HavenCore
@testable import HavenApp

/// A thermostat-only room reads *two* series off one entity — `current_temperature` and
/// `current_humidity`, same entity id, same range. Keyed on entity and range alone those are
/// one cache entry, so both lanes of the chart would plot whichever landed first: two lines
/// with identical shapes, one of them silently mislabelled.
@Suite @MainActor struct HistoryCacheKeyTests {
    @Test func attributeSeriesDoNotShareACacheEntry() {
        let store = HomeStore()
        let temp = HistorySeries(points: [HistoryPoint(time: Date(timeIntervalSince1970: 0), value: 20.5)])
        let humid = HistorySeries(points: [HistoryPoint(time: Date(timeIntervalSince1970: 0), value: 44)])

        store.historyCache.byKey[HomeStore.historyKey("climate.lr", .day, "current_temperature")] = (temp, Date())
        store.historyCache.byKey[HomeStore.historyKey("climate.lr", .day, "current_humidity")] = (humid, Date())

        #expect(store.history("climate.lr", .day, attribute: "current_temperature")?.points.first?.value == 20.5)
        #expect(store.history("climate.lr", .day, attribute: "current_humidity")?.points.first?.value == 44)
    }

    /// A state-sourced lookup must not collide with an attribute-sourced one on the same entity.
    @Test func stateAndAttributeSeriesDoNotShareACacheEntry() {
        let store = HomeStore()
        store.historyCache.byKey[HomeStore.historyKey("climate.lr", .day, nil)] =
            (HistorySeries(points: [HistoryPoint(time: Date(timeIntervalSince1970: 0), value: 1)]), Date())
        #expect(store.history("climate.lr", .day) != nil)
        #expect(store.history("climate.lr", .day, attribute: "current_temperature") == nil)
    }

    /// Ranges stay separate, as they always have.
    @Test func rangesStillDoNotShareACacheEntry() {
        let store = HomeStore()
        store.historyCache.byKey[HomeStore.historyKey("sensor.t", .day, nil)] =
            (HistorySeries(points: [HistoryPoint(time: Date(timeIntervalSince1970: 0), value: 1)]), Date())
        #expect(store.history("sensor.t", .day) != nil)
        #expect(store.history("sensor.t", .week) == nil)
    }
}
