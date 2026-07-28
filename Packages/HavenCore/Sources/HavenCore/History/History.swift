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

    /// How long a fetched series stays usable before it is re-fetched.
    ///
    /// Scaled to how fast the underlying data actually moves rather than picked as one number: a
    /// Day chart is drawn from hourly buckets and goes stale within the hour, while a Year chart
    /// built from monthly ones cannot meaningfully change between two glances on the same evening.
    /// Before this the cache had no expiry at all, so a chart opened at breakfast still showed
    /// breakfast's data at dinner without the app ever having been quit.
    public var cacheLifetime: TimeInterval {
        switch self {
        case .day: 300            // 5 minutes
        case .week: 1_800         // 30 minutes
        case .month, .threeMonths: 3_600
        case .year: 21_600        // 6 hours
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
    ///
    /// Invariant: an empty series always has `min == nil` and `max == nil`, regardless
    /// of what overrides are passed in — non-nil min/max implies plottable data exists,
    /// which chart-rendering code relies on for axis ranges.
    public init(points: [HistoryPoint], min: Double? = nil, max: Double? = nil, avg: Double? = nil) {
        self.points = points
        guard !points.isEmpty else {
            self.min = nil
            self.max = nil
            self.avg = nil
            return
        }
        self.min = min ?? points.map(\.value).min()
        self.max = max ?? points.map(\.value).max()
        self.avg = avg ?? points.map(\.value).reduce(0, +) / Double(points.count)
    }
}

/// One moment an entity's state became something new. See `HistoryParsing.stateChanges`.
public struct StateChange: Sendable, Equatable {
    public let time: Date
    public let state: String
    public init(time: Date, state: String) { self.time = time; self.state = state }
}

public enum HistoryParsing {
    /// Statistics rows may carry `start` either as milliseconds-since-epoch (a JSON
    /// number, older/other HA versions) or as an ISO-8601 string (modern HA, e.g.
    /// `"2026-07-25T10:00:00+00:00"`). Accept both; return nil if neither parses.
    static func parseStatisticsStart(_ value: JSONValue?) -> Date? {
        guard let value else { return nil }
        if let ms = value.asDouble {
            return Date(timeIntervalSince1970: ms / 1000.0)
        }
        if let s = value.asString {
            let withoutFractional = ISO8601DateFormatter()
            withoutFractional.formatOptions = [.withInternetDateTime]
            if let d = withoutFractional.date(from: s) { return d }
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = withFractional.date(from: s) { return d }
        }
        return nil
    }

    /// Parses `recorder/statistics_during_period` responses: keyed by statistic id,
    /// rows carry `start` (ms epoch number or ISO-8601 string) and a value from
    /// `mean` (fallback `state`, fallback `sum` for total/total_increasing sensors).
    public static func fromStatistics(_ result: JSONValue, statisticId: String) -> HistorySeries {
        let arr = result.asObject?[statisticId]?.asArray ?? []
        let pts = arr.compactMap { row -> HistoryPoint? in
            guard let o = row.asObject, let start = parseStatisticsStart(o["start"]),
                  let mean = (o["mean"]?.asDouble ?? o["state"]?.asDouble ?? o["sum"]?.asDouble) else { return nil }
            return HistoryPoint(time: start, value: mean)
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

    /// Parses `history/history_during_period` rows for a value carried in an *attribute* rather
    /// than in the entity's state — a thermostat's `current_temperature`, whose state is
    /// "heat"/"cool"/"off".
    ///
    /// Requires the request to have been made with `no_attributes: false` (see
    /// `WSCommand.historyDuringPeriod(includeAttributes:)`); rows fetched without it carry no
    /// `a` key at all and every one of them is dropped here.
    ///
    /// Every row carries a *full* attribute dictionary — verified against HA's
    /// `row_to_compressed_state`, which sets it unconditionally when `no_attributes` is false —
    /// so there is deliberately no carry-forward of the last-seen value. A row without a usable
    /// number is dropped rather than held over, because an unavailable thermostat should leave a
    /// gap in the line, not a plateau at its last reading.
    public static func fromHistory(_ result: JSONValue, entityId: String,
                                   attribute: String) -> HistorySeries {
        let arr = result.asObject?[entityId]?.asArray ?? []
        let pts = arr.compactMap { row -> HistoryPoint? in
            guard let o = row.asObject, let lu = o["lu"]?.asDouble,
                  let val = o["a"]?.asObject?[attribute]?.asDouble, val.isFinite else { return nil }
            return HistoryPoint(time: Date(timeIntervalSince1970: lu), value: val)
        }
        return HistorySeries(points: pts)
    }

    /// Parses `history/history_during_period` rows as a sequence of state *changes*, for an entity
    /// whose value is a word rather than a number — a binary sensor's "on"/"off", or its
    /// device-class reading of "open"/"closed".
    ///
    /// Deliberately not `fromHistory`: that one parses each row's state as a `Double` and drops
    /// what does not convert, which for a binary sensor is every row. The wire response needs no
    /// change — the compressed rows already carry `s` and `lu`.
    ///
    /// Newest first, `unavailable`/`unknown` dropped (a door that went offline did not open), and
    /// consecutive repeats collapsed to the moment the value *changed*. That last part is what
    /// makes this a list of events: Home Assistant records a row per update, not per change, so a
    /// sensor polling every 30 seconds otherwise yields hundreds of identical entries.
    public static func stateChanges(_ result: JSONValue, entityId: String) -> [StateChange] {
        let rows = result.asObject?[entityId]?.asArray ?? []
        var out: [StateChange] = []
        for row in rows {
            guard let o = row.asObject, let lu = o["lu"]?.asDouble,
                  let value = o["s"]?.asString,
                  !EntityState.unavailableStates.contains(value) else { continue }
            // Compared against the last *kept* row, so a run broken only by an `unavailable` gap
            // still reads as one continuous state rather than a spurious change back to itself.
            if out.last?.state == value { continue }
            out.append(StateChange(time: Date(timeIntervalSince1970: lu), state: value))
        }
        return out.reversed()
    }
}
