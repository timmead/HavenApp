import Foundation

public extension HomeConnection {
    /// A series for an entity, or for one named attribute of it.
    ///
    /// - Parameter attribute: when non-nil, the value is read from this attribute rather than
    ///   from the entity's state. Only `.day` can serve one: long-term statistics are keyed by
    ///   entity and computed from its *state*, so no attribute has statistics at any range. A
    ///   longer range returns an empty series without a round trip rather than asking a question
    ///   with no possible answer — and, more importantly, without letting `fromStatistics` read
    ///   the *entity's* own statistics and plot an unrelated number as the room's temperature.
    func history(entityId: String, attribute: String? = nil,
                 range: HistoryRange, now: Date) async throws -> HistorySeries {
        let start = now.addingTimeInterval(-range.seconds)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let startISO = f.string(from: start), endISO = f.string(from: now)
        if let attribute {
            guard !range.usesStatistics else { return HistorySeries(points: []) }
            let v = try await client.request {
                WSCommand.historyDuringPeriod(id: $0, entityId: entityId, startISO: startISO,
                                              endISO: endISO, includeAttributes: true)
            }
            return HistoryParsing.fromHistory(v, entityId: entityId, attribute: attribute)
        }
        if range.usesStatistics {
            let v = try await client.request { WSCommand.statisticsDuringPeriod(id: $0, statisticId: entityId, startISO: startISO, endISO: endISO, period: range.period) }
            return HistoryParsing.fromStatistics(v, statisticId: entityId)
        } else {
            let v = try await client.request { WSCommand.historyDuringPeriod(id: $0, entityId: entityId, startISO: startISO, endISO: endISO) }
            return HistoryParsing.fromHistory(v, entityId: entityId)
        }
    }
}
