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
    @State private var range: HistoryRange = .day
    @State private var selectedDate: Date?

    private var temperature: UpliftedSensor? { sensors.first { $0.role == .temperature } }
    private var humidity: UpliftedSensor? { sensors.first { $0.role == .humidity } }

    private var temperatureAccent: Color { HavenColor.domain(.climate) }
    private var humidityAccent: Color { HavenColor.domain(.cover) }

    var body: some View {
        // Sized to its content like every other sheet in the app, rather than the full-screen
        // `NavigationStack` this started as — see `FittedSheet`. The room name is a plain heading
        // here rather than a navigation title because there is nothing to navigate: this sheet
        // has one screen, and a `NavigationStack` for it bought a nav bar, a "Done" button
        // duplicating the drag-to-dismiss every other modal uses, and a sheet that always took
        // the whole display.
        //
        // No trailing `Spacer()`, deliberately: one would report whatever height it was offered
        // and defeat the measurement entirely.
        VStack(alignment: .leading, spacing: 12) {
            Text(roomName).font(.system(size: 17, weight: .bold))
            FacetCard {
                readoutRow
                chartOrPlaceholder
                HavenSegmented(options: HistoryRange.allCases, selection: $range,
                               label: { $0.label }, accent: temperatureAccent)
                unavailableNote
            }
        }
        .fittedSheet()
        .task(id: range) {
            for sensor in sensors {
                await store.loadHistory(sensor.entityId, range: range, attribute: sensor.attributeName)
            }
        }
        .onChange(of: range) { selectedDate = nil }
    }

    /// Live values on the left, scrub readout on the right. Unlike `SensorModal`'s version of
    /// this layout — which gets away with a plain `.firstTextBaseline` `HStack` because its
    /// readout is a single line of small text sitting inside 30pt text's baseline envelope — this
    /// readout is one line *per sensor*, and a `VStack` reports `.firstTextBaseline` from its
    /// *first* subview only. With two sensors, the second caption line hangs entirely below that
    /// shared baseline, so inserting the column only while scrubbing (`if let selectedDate`)
    /// would grow the row the instant a selection registers, shifting the chart under the finger
    /// that just landed on it.
    ///
    /// So the readout column is always present, at a fixed one-line-per-sensor height — one
    /// `Text` per sensor whether or not there's a selection, and whether or not that sensor has a
    /// point at the selected date — and only its opacity toggles with `selectedDate`. That is
    /// what actually guarantees the property that matters here: the row's height cannot change
    /// between scrubbing and not, because the same subviews are always laid out.
    ///
    /// Height alone isn't the whole story: at rest each line is the one-character `"—"`, while
    /// scrubbing it grows to something like `"21.5°C · 14:32"` — nearly ten times as wide — and an
    /// `HStack` sizes its `Spacer` from whatever room is left, so the live-value block on the left
    /// would shift horizontally the instant a finger lands. `readoutMinWidth` reserves a floor for
    /// the column sized to comfortably fit the strings this row produces at default text size, so
    /// the ordinary rest → scrub transition doesn't move anything to its left — it only reveals
    /// text that was already reserved space. It is a floor, not a hard pin: it is a fixed constant,
    /// not measured off actual content, so a longer localized string (a wider Dynamic Type size, a
    /// long month name) can still exceed it and grow the row past this reservation. Structurally
    /// pinning it against that too would mean reserving space with a hidden widest-case string
    /// rather than a constant — left as a known gap rather than done here.
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
            VStack(alignment: .trailing, spacing: 1) {
                ForEach(sensors) { sensor in
                    Text(scrubLine(for: sensor))
                        .font(.caption)
                        .foregroundStyle(accent(sensor.role))
                }
            }
            .frame(minWidth: readoutMinWidth, alignment: .trailing)
            .opacity(selectedDate == nil ? 0 : 1)
            .accessibilityHidden(selectedDate == nil)
        }
    }

    /// A width comfortably wider than the longest string `scrubLine` ever produces — e.g.
    /// `"-40.0°C · 14:32"` or `"100% · Jul 27"` — at `.caption` size, so reserving it up front
    /// guarantees the readout column never grows between rest (`"—"`) and mid-scrub, regardless
    /// of locale or which of temperature/humidity is showing. Not measured off the actual string
    /// (that would make the guarantee depend on content, the exact bug this fixes), just a fixed
    /// constant chosen to outsize it.
    private let readoutMinWidth: CGFloat = 110

    /// The scrub readout's text for one sensor, or a placeholder when there's no selection or no
    /// point near it — always one line, never an absent one, so the readout column's height is
    /// fixed regardless of what's actually being scrubbed to.
    private func scrubLine(for sensor: UpliftedSensor) -> String {
        guard let selectedDate, let point = nearestPoint(to: selectedDate, in: points(for: sensor))
        else { return "—" }
        return scrubText(sensor, point)
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
        // Each axis's range comes from `EnvironmentAxisBounds` — a fixed band for ordinary indoor
        // values, grown outward in whole steps only when the data leaves it. Fitting the axis to
        // the data instead (what this used to do) made a room that drifted half a degree fill the
        // whole chart, and relabelled the axis every time the data moved.
        let tempDomain = temperature.flatMap { axisDomain(for: $0) }
        let humidDomain = humidity.flatMap { axisDomain(for: $0) }

        // A projection only when *both* series are actually plotted. One series is drawn against
        // its own axis directly; routing it through a projection would label a leading axis with
        // a domain nothing is plotted against.
        let scale = (!tempPoints.isEmpty && !humidPoints.isEmpty)
            ? tempDomain.flatMap { t in humidDomain.map { DualAxisScale(primary: t, secondary: $0) } }
            : nil

        // Pinned once and used twice — by the area fill's floor and by the Y scale below. They
        // have to be the same value: see the `yStart` comment on the `AreaMark`.
        let domain = scale?.primaryDomain
            ?? (tempPoints.isEmpty ? humidDomain : tempDomain)
            ?? 0...1

        Chart {
            ForEach(tempPoints, id: \.time) { p in
                // `yStart` is load-bearing. A plain `AreaMark(x:y:)` fills from the value down to
                // **zero**, not to the bottom of the chart — and this chart's Y domain is pinned
                // to the data's own range (roughly 24…27°C for a room), so zero sits far outside
                // it. The fill then runs hundreds of points past the plot rect and, unclipped,
                // paints straight down the sheet below the chart. Anchoring it to the domain's
                // own floor bounds it to the plot area by construction rather than by relying on
                // clipping, and makes the shaded region mean something: temperature above the
                // bottom of the visible scale.
                AreaMark(x: .value("Time", p.time),
                         yStart: .value("Floor", domain.lowerBound),
                         yEnd: .value("Temperature", p.value))
                    .interpolationMethod(.catmullRom)
                    // A gradient, not a flat wash, because the axis no longer hugs the data. A
                    // fitted axis made this fill a thin ribbon under the line; against a fixed
                    // 15–30°C band a 24°C room fills roughly two-thirds of the chart, and at a
                    // flat 18% opacity that is a slab of colour competing with the line it is
                    // meant to support. Fading to clear keeps the temperature series visually
                    // weighted without turning the plot into a block.
                    .foregroundStyle(.linearGradient(
                        colors: [temperatureAccent.opacity(0.22), temperatureAccent.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                // `series:` is load-bearing, not decoration: Swift Charts joins LineMarks into
                // one continuous path by `series:` (or `foregroundStyle(by:)`) alone — the
                // `.value("Temperature", …)` / `.value("Humidity", …)` labels below only name the
                // encoding for axes and legends, they do not separate series. Drop this and the
                // two lines silently stitch into a single zig-zag connecting the end of one
                // series to the start of the other.
                LineMark(x: .value("Time", p.time), y: .value("Temperature", p.value),
                         series: .value("Series", "temperature"))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(temperatureAccent)
            }
            ForEach(humidPoints, id: \.time) { p in
                LineMark(x: .value("Time", p.time),
                         y: .value("Humidity", scale?.project(p.value) ?? p.value),
                         series: .value("Series", "humidity"))
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
        .chartYScale(domain: domain)
        .chartYAxis {
            // Stepped rather than automatic, so the leading axis reads 15/20/25/30 instead of
            // whatever Swift Charts picks for a range it did not choose. The step comes from the
            // same band that set the domain, so labels stay round when the axis grows.
            AxisMarks(position: .leading, values: leadingTicks(in: domain))
            if let scale, let humidStep = humidity.flatMap({ axisStep(for: $0) }) {
                AxisMarks(position: .trailing,
                          values: scale.secondaryTicks(step: humidStep).map(\.position)) { axis in
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

    /// The unit a sensor is currently reporting in — which is also what decides *which* band
    /// applies. An entity that is currently unavailable reports none, and falls back to a
    /// data-fitted axis; see `EnvironmentAxisBounds.domain(role:unit:series:)`.
    private func unit(for sensor: UpliftedSensor) -> String {
        EnvironmentReading.unit(sensor, state: store.state(sensor.entityId))
    }

    /// The axis range for one sensor: its band, grown outward in whole steps to fit the data.
    private func axisDomain(for sensor: UpliftedSensor) -> ClosedRange<Double>? {
        EnvironmentAxisBounds.domain(role: sensor.role, unit: unit(for: sensor),
                                     series: seriesFor(sensor))
    }

    /// The tick spacing that keeps `sensor`'s axis labels round, or nil for a unit with no band.
    private func axisStep(for sensor: UpliftedSensor) -> Double? {
        EnvironmentAxisBounds.band(role: sensor.role, unit: unit(for: sensor))?.step
    }

    /// Leading-axis tick values — the temperature sensor's step when temperature is what's plotted
    /// there, otherwise humidity's, since a humidity-only room draws humidity against the leading
    /// axis. A unit with no band has a data-fitted domain and so no round step to impose; quarters
    /// of the range are as good an answer as any and keep the axis from being unlabelled.
    private func leadingTicks(in domain: ClosedRange<Double>) -> [Double] {
        let leading = (temperature.map { !points(for: $0).isEmpty } == true) ? temperature : humidity
        let step = leading.flatMap { axisStep(for: $0) }
            ?? (domain.upperBound - domain.lowerBound) / 4
        return EnvironmentAxisBounds.ticks(in: domain, step: step)
    }

    private func scrubText(_ sensor: UpliftedSensor, _ point: HistoryPoint) -> String {
        // The sensor's real unit, not a hardcoded "°" — `EnvironmentReading.format` is the one
        // place a number becomes text, shared with the pill above, so a Fahrenheit home doesn't
        // get a pill reading `71.6°F` and a scrub readout reading `71.6°` one row below.
        let unit = EnvironmentReading.unit(sensor, state: store.state(sensor.entityId))
        let value = EnvironmentReading.format(point.value, role: sensor.role, unit: unit)
        return "\(value) · \(point.time.formatted(scrubTimestampFormat))"
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
