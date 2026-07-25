import Foundation

public enum HistoryRange: Sendable, CaseIterable {
    case day, week, month, threeMonths, year

    public var label: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .threeMonths: "3M"
        case .year: "Year"
        }
    }

    public var seconds: TimeInterval {
        switch self {
        case .day: 86_400
        case .week: 604_800
        case .month: 2_592_000
        case .threeMonths: 7_776_000
        case .year: 31_536_000
        }
    }

    /// Day uses raw history; longer ranges use long-term statistics.
    public var usesStatistics: Bool { self != .day }

    public var period: String {
        switch self {
        case .day: "hour"
        case .week: "hour"
        case .month: "day"
        case .threeMonths: "day"
        case .year: "month"
        }
    }
}

public struct HistoryPoint: Sendable, Equatable {
    public let time: Date
    public let value: Double

    public init(time: Date, value: Double) {
        self.time = time
        self.value = value
    }
}

public struct HistorySeries: Sendable, Equatable {
    public let points: [HistoryPoint]
    public let min: Double?
    public let max: Double?
    public let avg: Double?

    /// `min`/`max`/`avg` default to being derived from `points`, but callers (e.g. the
    /// statistics parser) may supply series-level values sourced directly from the
    /// payload, which take precedence over the per-point derivation.
    public init(points: [HistoryPoint], min: Double? = nil, max: Double? = nil, avg: Double? = nil) {
        self.points = points
        self.min = min ?? points.map(\.value).min()
        self.max = max ?? points.map(\.value).max()
        self.avg = avg ?? (points.isEmpty ? nil : points.map(\.value).reduce(0, +) / Double(points.count))
    }
}

public enum HistoryParsing {
    /// Parses `recorder/statistics_during_period` responses: keyed by statistic id,
    /// rows carry `start` in milliseconds since epoch and a `mean` (fallback `state`).
    public static func fromStatistics(_ result: JSONValue, statisticId: String) -> HistorySeries {
        let arr = result.asObject?[statisticId]?.asArray ?? []
        let pts = arr.compactMap { row -> HistoryPoint? in
            guard let o = row.asObject, let start = o["start"]?.asDouble,
                  let mean = (o["mean"]?.asDouble ?? o["state"]?.asDouble) else { return nil }
            return HistoryPoint(time: Date(timeIntervalSince1970: start / 1000.0), value: mean)
        }
        // Statistics rows may carry their own min/max (distinct from the mean series);
        // prefer those over deriving min/max from the plotted mean values.
        let rowMins = arr.compactMap { $0.asObject?["min"]?.asDouble }
        let rowMaxes = arr.compactMap { $0.asObject?["max"]?.asDouble }
        return HistorySeries(points: pts, min: rowMins.min(), max: rowMaxes.max())
    }

    /// Parses `history/history_during_period` (`minimal_response`) responses: keyed by
    /// entity id, compact rows use `s` (state, a string) and `lu` (last-updated, seconds
    /// since epoch). Non-numeric states (e.g. "nan", "unavailable") are dropped.
    public static func fromHistory(_ result: JSONValue, entityId: String) -> HistorySeries {
        let arr = result.asObject?[entityId]?.asArray ?? []
        let pts = arr.compactMap { row -> HistoryPoint? in
            guard let o = row.asObject, let lu = o["lu"]?.asDouble,
                  let val = Double(o["s"]?.asString ?? ""), val.isFinite else { return nil }
            return HistoryPoint(time: Date(timeIntervalSince1970: lu), value: val)
        }
        return HistorySeries(points: pts)
    }
}
