import SwiftUI
import Charts
import HavenCore

/// A day of a sensor's readings, drawn as a line with no axes, no labels and no interaction.
///
/// **Deliberately not a small chart.** `SensorModal` draws a chart: axes, a selection cursor, avg and
/// min/max beneath. This is the same data with all of that removed, because a tile is glanced at and
/// a glance cannot read an axis. What survives is the shape — rising, falling, steady, spiky — which
/// is the only question a quarter-second look is asking.
///
/// It renders **nothing at all** when there is no series, one point, or a flat line with no range.
/// That is the same refusal `SensorModal` makes rather than draw "an empty Chart with an arbitrary
/// axis", and it matters more here: a tile has no room to explain that the line it is showing means
/// nothing, so the honest rendering of no history is no line.
struct SensorSparkline: View {
    let series: HistorySeries?
    let accent: Color

    /// The points, or nil when there is nothing worth drawing.
    ///
    /// Two points is the floor: a single reading has no shape, and `Chart` would draw it as a dot
    /// that reads like a data point on an axis nobody can see.
    private var drawable: [HistoryPoint]? {
        guard let points = series?.points, points.count >= 2 else { return nil }
        return points
    }

    /// The vertical range to draw across, given the points.
    ///
    /// Padded by a twentieth so the line never runs along the tile's own edge, and widened around a
    /// **flat** series rather than collapsing to a zero-height domain: a sensor that read the same
    /// number all day is a real answer, and the honest drawing of it is a line through the middle.
    private func domain(of points: [HistoryPoint]) -> ClosedRange<Double> {
        let values = points.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        guard high > low else { return (low - 0.5)...(high + 0.5) }
        let padding = (high - low) / 20
        return (low - padding)...(high + padding)
    }

    var body: some View {
        if let points = drawable {
            Chart {
                ForEach(points, id: \.time) { p in
                    AreaMark(x: .value("Time", p.time), y: .value("Value", p.value))
                        .foregroundStyle(.linearGradient(colors: [accent.opacity(0.13),
                                                                  accent.opacity(0.01)],
                                                         startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", p.time), y: .value("Value", p.value))
                        .foregroundStyle(accent.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            // **The y-domain is the data's own range, stated rather than inferred.** A room that sat
            // between 20.8 and 21.4 all day is a flat line against a zero baseline — which says
            // "nothing happened" when something did — and `.automatic(includesZero: false)` still
            // pads enough to flatten it. The shape is the whole point of a sparkline, so the shape
            // gets the whole height.
            .chartYScale(domain: domain(of: points))
            // Nothing here is interactive: the tile's own tap opens the modal, and a chart that
            // swallowed it would make the tile the one thing on the dashboard that cannot be opened.
            .allowsHitTesting(false)
        }
    }
}
