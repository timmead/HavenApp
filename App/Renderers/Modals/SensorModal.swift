import SwiftUI
import Charts
import HavenCore

struct SensorModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var range: HistoryRange = .day
    @State private var selectedDate: Date?

    var body: some View {
        let e = store.state(entityId)
        let s = e.map(SensorState.init)
        let series = store.history(entityId, range)
        let accent = HavenColor.domain(.sensor)
        let unit = s?.unit ?? ""

        VStack(spacing: 12) {
            ModalHeader(systemImage: IconMap.symbol(domain: .sensor, deviceClass: e?.deviceClass),
                        title: TileName.of(entityId, e), subtitle: "", accent: accent) { dismiss() }

            FacetCard {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(s?.value ?? "—").font(.system(size: 30, weight: .bold))
                    Text(s?.unit ?? "").foregroundStyle(.secondary)
                }

                if let series, !series.points.isEmpty {
                    let selected = nearestPoint(to: selectedDate, in: series.points)

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
                                .foregroundStyle(.secondary.opacity(0.5))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            PointMark(x: .value("Time", selected.time), y: .value("Value", selected.value))
                                .foregroundStyle(accent)
                                .symbolSize(80)
                                .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                    VStack(spacing: 2) {
                                        Text(unit.isEmpty ? String(format: "%.1f", selected.value) : "\(String(format: "%.1f", selected.value)) \(unit)")
                                            .font(.caption.weight(.semibold))
                                        Text(selected.time, format: .dateTime.month().day().hour().minute())
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(HavenColor.glassFill)
                                    }
                                }
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

            Spacer()
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

    @ViewBuilder private func stat(_ l: String, _ v: Double?) -> some View {
        VStack(alignment: .leading) {
            Text(l).font(.caption2).foregroundStyle(.secondary)
            Text(v.map { String(format: "%.1f", $0) } ?? "—").font(.system(size: 14, weight: .semibold))
        }
    }
}
