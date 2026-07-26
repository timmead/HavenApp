import SwiftUI
import Charts
import HavenCore

struct SensorModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var range: HistoryRange = .day

    var body: some View {
        let e = store.state(entityId)
        let s = e.map(SensorState.init)
        let series = store.history(entityId, range)
        let accent = HavenColor.domain(.sensor)

        VStack(spacing: 12) {
            ModalHeader(systemImage: IconMap.symbol(domain: .sensor, deviceClass: e?.deviceClass),
                        title: TileName.of(entityId, e), subtitle: "", accent: accent) { dismiss() }

            FacetCard {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(s?.value ?? "—").font(.system(size: 30, weight: .bold))
                    Text(s?.unit ?? "").foregroundStyle(.secondary)
                }

                if let series, !series.points.isEmpty {
                    Chart(series.points, id: \.time) { p in
                        AreaMark(x: .value("Time", p.time), y: .value("Value", p.value))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(accent.opacity(0.2))
                        LineMark(x: .value("Time", p.time), y: .value("Value", p.value))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(accent)
                    }
                    .frame(height: 150)
                    .chartXAxis(.hidden)
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
    }

    @ViewBuilder private func stat(_ l: String, _ v: Double?) -> some View {
        VStack(alignment: .leading) {
            Text(l).font(.caption2).foregroundStyle(.secondary)
            Text(v.map { String(format: "%.1f", $0) } ?? "—").font(.system(size: 14, weight: .semibold))
        }
    }
}
