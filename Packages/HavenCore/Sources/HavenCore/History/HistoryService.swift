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

    /// A day of history for several entities, in one request.
    ///
    /// **One command, one series per entity**, keyed by entity id — which is how the reply already
    /// arrives, so each entity is parsed by exactly the same code that parses a single-entity
    /// response.
    ///
    /// An entity the recorder has nothing for comes back as an **empty series rather than a missing
    /// key**. A caller that asked for six and got five back cannot tell "no data" from "the request
    /// dropped it", and would keep asking forever; an empty series is an answer.
    ///
    /// **A statistics range is answered one entity at a time**, correctly rather than quickly.
    /// `recorder/statistics_during_period` takes a list too, but nothing batchable asks for one — a
    /// sparkline is always `.day`, and the longer ranges belong to modals opened one at a time. What
    /// this must not do is send a *history* command for a range that needs statistics, which is a
    /// silently wrong window rather than an error.
    func histories(entityIds: [String], attribute: String? = nil,
                   range: HistoryRange, now: Date) async throws -> [String: HistorySeries] {
        guard !entityIds.isEmpty else { return [:] }
        guard !range.usesStatistics else {
            var out: [String: HistorySeries] = [:]
            for id in entityIds {
                out[id] = try await history(entityId: id, attribute: attribute, range: range, now: now)
            }
            return out
        }
        let start = now.addingTimeInterval(-range.seconds)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let startISO = f.string(from: start), endISO = f.string(from: now)
        let v = try await client.request {
            WSCommand.historyDuringPeriod(id: $0, entityIds: entityIds, startISO: startISO,
                                          endISO: endISO, includeAttributes: attribute != nil)
        }
        return Dictionary(uniqueKeysWithValues: entityIds.map { id in
            if let attribute {
                return (id, HistoryParsing.fromHistory(v, entityId: id, attribute: attribute))
            }
            return (id, HistoryParsing.fromHistory(v, entityId: id))
        })
    }

    /// A binary sensor's recent state changes. Always raw history, never statistics: statistics
    /// are numeric aggregates and a binary sensor has no mean.
    func stateChanges(entityId: String, range: HistoryRange, now: Date) async throws -> [StateChange] {
        let start = now.addingTimeInterval(-range.seconds)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let v = try await client.request {
            WSCommand.historyDuringPeriod(id: $0, entityId: entityId,
                                          startISO: f.string(from: start), endISO: f.string(from: now))
        }
        return HistoryParsing.stateChanges(v, entityId: entityId)
    }
}
