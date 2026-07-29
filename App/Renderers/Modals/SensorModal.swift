import SwiftUI
import Charts
import HavenCore

struct SensorModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @State private var range: HistoryRange = .day
    @State private var selectedDate: Date?

    var body: some View {
        let e = store.state(entityId)
        let s = e.map(SensorState.init)
        let series = store.history(entityId, range)
        let accent = HavenColor.domain(.sensor)
        let unit = s?.unit ?? ""

        // `SensorState.value` is the raw state string, so an unreachable sensor rendered the
        // literal word "unavailable" at 30pt where its number goes, with its unit still beside it
        // — a reading that isn't one, stated more loudly than any real value. Named in the
        // subtitle instead, and the value falls back to the em-dash it already uses for "no data".
        let unavailable = e?.state == "unavailable"
        let unknown = e?.state == "unknown"
        VStack(spacing: 12) {
            ModalHeader(systemImage: IconMap.symbol(domain: .sensor, deviceClass: e?.deviceClass),
                        title: store.displayName(of: entityId),
                        subtitle: unavailable ? "Unavailable" : (unknown ? "Unknown" : ""),
                        accent: accent, unavailable: unavailable)

            FacetCard {
                let selected = series.flatMap { nearestPoint(to: selectedDate, in: $0.points) }

                // A single baseline-aligned row: the left (current value) and right
                // (scrub readout) groups share one `.firstTextBaseline` HStack rather
                // than nesting a VStack on the right, so the row's height is always
                // governed by the 30pt current-value text — adding the smaller scrub
                // readout beside it (not beneath it) can't grow the row and cause the
                // chart/segmented-control/stats below to shift when scrubbing starts.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text((unavailable || unknown) ? "—" : (s?.value ?? "—"))
                        .font(.system(size: 30, weight: .bold))
                    // The unit is suppressed with the value: "— °C" claims a scale for a reading
                    // that does not exist.
                    Text((unavailable || unknown) ? "" : (s?.unit ?? "")).foregroundStyle(.secondary)

                    Spacer()

                    if let selected {
                        Text(String(format: "%.1f", selected.value))
                            .font(.headline)
                        if !unit.isEmpty {
                            Text(unit).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text(selected.time, format: scrubTimestampFormat)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(sensorReadoutLabel(current: s, selected: selected, unit: unit))

                if let series, !series.points.isEmpty {
                    Chart {
                        ForEach(series.points, id: \.time) { p in
                            AreaMark(x: .value("Time", p.time), y: .value("Value", p.value))
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(accent.opacity(0.2))
                            LineMark(x: .value("Time", p.time), y: .value("Value", p.value))
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(accent)
                        }

                        if let selected {
                            RuleMark(x: .value("Time", selected.time))
                                .foregroundStyle(.secondary)
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            PointMark(x: .value("Time", selected.time), y: .value("Value", selected.value))
                                .foregroundStyle(accent)
                                .symbolSize(80)
                        }
                    }
                    .frame(height: 150)
                    .chartXAxis(.hidden)
                    .chartXSelection(value: $selectedDate)
                } else {
                    // No plottable data yet (fresh load, or a non-numeric sensor whose
                    // history rows were all dropped) — show a calm placeholder rather
                    // than an empty Chart with an arbitrary/misleading axis.
                    RoundedRectangle(cornerRadius: 12)
                        .fill(HavenColor.glassFill)
                        .frame(height: 150)
                        .overlay {
                            Text("No history yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                }

                HavenSegmented(options: HistoryRange.allCases, selection: $range, label: { $0.label }, accent: accent)

                if let series {
                    HStack(spacing: 16) {
                        stat("Avg", series.avg)
                        stat("Min", series.min)
                        stat("Max", series.max)
                    }
                }
            }

        }
        .task(id: range) { await store.loadHistory(entityId, range: range) }
        .onChange(of: range) { selectedDate = nil }
    }

    /// Finds the `HistoryPoint` closest in time to `date`. The chart selection is a
    /// continuous x-value, but our series is discrete points, so we snap to the
    /// nearest one rather than requiring an exact match.
    private func nearestPoint(to date: Date?, in points: [HistoryPoint]) -> HistoryPoint? {
        guard let date else { return nil }
        return points.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
    }

    /// A compact, range-appropriate readout for the scrubbed timestamp: a short time
    /// for Day (where the whole series spans a single day, so the date is redundant),
    /// otherwise a short date (where the time-of-day is the redundant part).
    private var scrubTimestampFormat: Date.FormatStyle {
        range == .day
            ? .dateTime.hour().minute()
            : .dateTime.month(.abbreviated).day()
    }

    @ViewBuilder private func stat(_ l: String, _ v: Double?) -> some View {
        VStack(alignment: .leading) {
            Text(l).font(.caption2).foregroundStyle(.secondary)
            Text(v.map { String(format: "%.1f", $0) } ?? "—").font(.system(size: 14, weight: .semibold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(l), \(v.map { String(format: "%.1f", $0) } ?? "no data")")
    }

    /// Combined label for the current-value row: the live reading, plus the scrubbed
    /// point's value/time when the chart is being scrubbed — otherwise just the former.
    private func sensorReadoutLabel(current: SensorState?, selected: HistoryPoint?, unit: String) -> String {
        let unitSuffix = unit.isEmpty ? "" : " \(unit)"
        let live = "\(current?.value ?? "—")\(unitSuffix)"
        guard let selected else { return live }
        let time = selected.time.formatted(scrubTimestampFormat)
        return "\(live), at \(time): \(String(format: "%.1f", selected.value))\(unitSuffix)"
    }
}
