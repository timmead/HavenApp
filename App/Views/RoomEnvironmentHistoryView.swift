import SwiftUI
import Charts
import HavenCore

/// A room's temperature and humidity over time, on one chart with two Y axes.
///
/// One chart rather than two stacked ones because the question this answers is a *relationship* —
/// humidity climbing while temperature falls is the thing a person opens this to see, and two
/// charts make that a memory exercise. Swift Charts has a single Y scale, so the humidity series
/// is projected into the temperature's domain (`DualAxisScale`) and the trailing axis is labelled
/// with the inverse. All of that arithmetic is in HavenCore under test; this file only draws.
struct RoomEnvironmentHistoryView: View {
    let roomName: String
    let sensors: [UpliftedSensor]
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var range: HistoryRange = .day
    @State private var selectedDate: Date?

    private var temperature: UpliftedSensor? { sensors.first { $0.role == .temperature } }
    private var humidity: UpliftedSensor? { sensors.first { $0.role == .humidity } }

    private var temperatureAccent: Color { HavenColor.domain(.climate) }
    private var humidityAccent: Color { HavenColor.domain(.cover) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    FacetCard {
                        readoutRow
                        chartOrPlaceholder
                        HavenSegmented(options: HistoryRange.allCases, selection: $range,
                                       label: { $0.label }, accent: temperatureAccent)
                        unavailableNote
                    }
                }
                .padding()
            }
            .navigationTitle(roomName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: range) {
            for sensor in sensors {
                await store.loadHistory(sensor.entityId, range: range, attribute: sensor.attributeName)
            }
        }
        .onChange(of: range) { selectedDate = nil }
    }

    /// Live values on the left, scrub readout on the right — the `SensorModal` arrangement, and
    /// for its reason: both groups share one `.firstTextBaseline` row so that starting to scrub
    /// cannot change the row's height and shift the chart underneath the finger doing it.
    private var readoutRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ForEach(sensors) { sensor in
                HStack(spacing: 4) {
                    Image(systemName: sensor.role == .temperature ? "thermometer.medium" : "humidity.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(accent(sensor.role))
                    Text(EnvironmentReading.display(sensor, state: store.state(sensor.entityId)))
                        .font(.system(size: 22, weight: .bold))
                }
            }
            Spacer(minLength: 4)
            if let selectedDate {
                VStack(alignment: .trailing, spacing: 1) {
                    ForEach(sensors) { sensor in
                        if let point = nearestPoint(to: selectedDate, in: points(for: sensor)) {
                            Text(scrubText(sensor, point))
                                .font(.caption)
                                .foregroundStyle(accent(sensor.role))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var chartOrPlaceholder: some View {
        let tempPoints = temperature.map(points(for:)) ?? []
        let humidPoints = humidity.map(points(for:)) ?? []
        if tempPoints.isEmpty && humidPoints.isEmpty {
            RoundedRectangle(cornerRadius: 12)
                .fill(HavenColor.glassFill)
                .frame(height: 170)
                .overlay { Text("No history yet").font(.caption).foregroundStyle(.secondary) }
        } else {
            chart(tempPoints: tempPoints, humidPoints: humidPoints)
                .frame(height: 170)
                .chartXAxis(.hidden)
                .chartXSelection(value: $selectedDate)
        }
    }

    /// The chart proper.
    ///
    /// Three shapes, not one: both series (dual axis), temperature only, humidity only. A single
    /// series is plotted on its own axis with no projection at all — routing it through
    /// `DualAxisScale` would label a leading axis with a domain nothing is plotted against.
    @ViewBuilder
    private func chart(tempPoints: [HistoryPoint], humidPoints: [HistoryPoint]) -> some View {
        let scale = (temperature != nil && humidity != nil)
            ? DualAxisScale(primary: seriesFor(temperature), secondary: seriesFor(humidity))
            : nil

        Chart {
            ForEach(tempPoints, id: \.time) { p in
                AreaMark(x: .value("Time", p.time), y: .value("Temperature", p.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(temperatureAccent.opacity(0.18))
                LineMark(x: .value("Time", p.time), y: .value("Temperature", p.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(temperatureAccent)
            }
            ForEach(humidPoints, id: \.time) { p in
                LineMark(x: .value("Time", p.time),
                         y: .value("Humidity", scale?.project(p.value) ?? p.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(humidityAccent)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
            if let selectedDate, let point = nearestPoint(to: selectedDate, in: tempPoints + humidPoints) {
                RuleMark(x: .value("Time", point.time))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        // The Y domain is pinned, not inferred. Swift Charts otherwise derives it from the
        // plotted marks and "nices" it to round numbers, and the trailing tick positions below
        // are computed against `primaryDomain` — so the two only agree by luck. They diverge for
        // real when a series comes from long-term statistics: `HistorySeries` prefers the
        // statistics rows' own min/max over the plotted means (see its initialiser), so
        // `primaryDomain` can be *wider* than anything actually drawn, putting the outermost
        // ticks outside the inferred domain, where Swift Charts drops them silently. Compiling
        // proves none of this; only pinning the domain does.
        .chartYScale(domain: scale?.primaryDomain ?? autoDomain(tempPoints + humidPoints))
        .chartYAxis {
            AxisMarks(position: .leading)
            if let scale {
                AxisMarks(position: .trailing,
                          values: scale.secondaryTicks(count: 4).map(\.position)) { axis in
                    AxisValueLabel {
                        // Labelled by inverting the projection: the position is temperature
                        // space, the number printed is humidity space.
                        if let position = axis.as(Double.self) {
                            Text("\(Int(scale.unproject(position).rounded()))%")
                        }
                    }
                    AxisGridLine().foregroundStyle(.clear)
                }
            }
        }
    }

    /// Names the series that could not be fetched, rather than leaving a lane silently absent.
    @ViewBuilder
    private var unavailableNote: some View {
        let missing = sensors.filter { points(for: $0).isEmpty && $0.attributeName != nil }
        if !missing.isEmpty, range.usesStatistics {
            Text("Only the last day is available for a thermostat’s readings.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// The domain for the single-series case, where there is no `DualAxisScale` to supply one.
    /// Mirrors `DualAxisScale`'s own flat-series padding so a room whose temperature has not
    /// moved gets a line through the middle rather than a zero-height scale.
    private func autoDomain(_ points: [HistoryPoint]) -> ClosedRange<Double> {
        let values = points.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        return lo < hi ? lo...hi : (lo - 0.5)...(lo + 0.5)
    }

    private func accent(_ role: UpliftedSensor.Role) -> Color {
        role == .temperature ? temperatureAccent : humidityAccent
    }

    private func points(for sensor: UpliftedSensor) -> [HistoryPoint] {
        seriesFor(sensor).points
    }

    private func seriesFor(_ sensor: UpliftedSensor?) -> HistorySeries {
        guard let sensor,
              let series = store.history(sensor.entityId, range, attribute: sensor.attributeName)
        else { return HistorySeries(points: []) }
        return series
    }

    private func scrubText(_ sensor: UpliftedSensor, _ point: HistoryPoint) -> String {
        let value = sensor.role == .temperature
            ? String(format: "%.1f", point.value)
            : String(Int(point.value.rounded()))
        let unit = sensor.role == .temperature ? "°" : "%"
        return "\(value)\(unit) · \(point.time.formatted(scrubTimestampFormat))"
    }

    /// Snaps a continuous chart selection to the nearest recorded point — same reasoning as
    /// `SensorModal.nearestPoint`.
    private func nearestPoint(to date: Date?, in points: [HistoryPoint]) -> HistoryPoint? {
        guard let date else { return nil }
        return points.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
    }

    private var scrubTimestampFormat: Date.FormatStyle {
        range == .day ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day()
    }
}
