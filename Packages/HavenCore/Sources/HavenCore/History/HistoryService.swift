import Foundation

public extension HomeConnection {
    func history(entityId: String, range: HistoryRange, now: Date) async throws -> HistorySeries {
        let start = now.addingTimeInterval(-range.seconds)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let startISO = f.string(from: start), endISO = f.string(from: now)
        if range.usesStatistics {
            let v = try await client.request { WSCommand.statisticsDuringPeriod(id: $0, statisticId: entityId, startISO: startISO, endISO: endISO, period: range.period) }
            return HistoryParsing.fromStatistics(v, statisticId: entityId)
        } else {
            let v = try await client.request { WSCommand.historyDuringPeriod(id: $0, entityId: entityId, startISO: startISO, endISO: endISO) }
            return HistoryParsing.fromHistory(v, entityId: entityId)
        }
    }
}
