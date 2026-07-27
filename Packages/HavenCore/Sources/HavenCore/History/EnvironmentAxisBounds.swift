import Foundation

/// The Y-axis range a room's temperature or humidity chart is drawn against.
///
/// Fitting the axis to the data — the obvious thing, and what this replaced — makes every chart
/// look dramatic and none of them comparable. A room that drifted 24.0→24.5°C over a day fills the
/// full height with what is really half a degree of noise, the axis relabels itself every time the
/// data shifts, and two rooms side by side can't be read against each other because neither shares
/// a scale. So the axis starts from a fixed band covering the ordinary case and only grows when
/// the data genuinely leaves it.
///
/// The consequence is deliberate and worth stating: a room that barely moves now *looks* like a
/// room that barely moves. That is the point — but it does mean small real variation is no longer
/// magnified into a mountain range.
///
/// ## Bands and steps are chosen together
///
/// A band is picked so that dividing it by its step lands on round numbers, because the tick
/// labels are what actually make a chart feel tidy. 15–30°C in 5° steps reads 15/20/25/30;
/// 30–70% in 10% steps reads 30/40/50/60/70. Growth snaps outward in whole steps for the same
/// reason — extending 30–70 to "whatever contains 22" would give 22–70 and ticks at 22/34/46/58/70.
public enum EnvironmentAxisBounds {
    /// A default band and the tick spacing that keeps its labels round.
    public struct Band: Sendable, Equatable {
        public let range: ClosedRange<Double>
        public let step: Double
        public init(_ range: ClosedRange<Double>, step: Double) {
            self.range = range; self.step = step
        }
    }

    /// Comfortable indoor humidity sits around 30–60% (the range ASHRAE recommends); the band runs
    /// to 70% so a humid summer room doesn't immediately push past it. Always a percentage — no
    /// integration reports relative humidity in anything else.
    public static let humidity = Band(30...70, step: 10)

    /// Indoor temperature bands, per unit. Deliberately keyed on the unit string rather than
    /// converted from a single canonical band: converting 15–30°C to Fahrenheit gives 59–86, and
    /// snapping *that* to round Fahrenheit steps is a worse way of saying 60–85 than simply saying
    /// 60–85.
    ///
    /// A unit this doesn't recognise gets no band at all — see `domain(role:unit:series:)`. That
    /// is the safe direction: guessing Celsius for a Fahrenheit home would put a 71°F reading 41
    /// degrees above a 15–30 band and produce a chart far worse than the data-fitted one.
    public static func temperature(unit: String) -> Band? {
        switch normalise(unit) {
        case "C": return Band(15...30, step: 5)
        case "F": return Band(60...85, step: 5)
        // 15–30°C is 288.15–303.15 K, which is not a multiple of anything. Widened to the nearest
        // round bounds rather than carried across precisely: an axis labelled 288/293/298/303 is
        // arithmetically faithful and reads like a serial number. See `everyBandIsStepAligned`.
        case "K": return Band(285...305, step: 5)
        default: return nil
        }
    }

    /// The last letter that identifies the scale, ignoring the degree sign and any spacing —
    /// Home Assistant reports `°C`, and has been seen to report a bare `C`.
    private static func normalise(_ unit: String) -> String {
        String(unit.uppercased().filter { $0.isLetter }.suffix(1))
    }

    /// The band for a role and unit, or nil when there isn't a sensible default one.
    public static func band(role: UpliftedSensor.Role, unit: String) -> Band? {
        role == .humidity ? humidity : temperature(unit: unit)
    }

    /// The axis range to draw `series` against.
    ///
    /// The band if the data fits inside it, the band grown outward in whole steps if not, and — for
    /// a unit with no band defined — the data's own range, which is what this whole type replaced
    /// but remains the honest answer when we don't know what scale the numbers are on.
    ///
    /// Note the unit can be unknown for a reason that has nothing to do with the integration:
    /// `EnvironmentReading.unit(_:state:)` falls back to a bare `"°"` when the entity is currently
    /// `unavailable`, because it reads the unit off the live state. So an offline Fahrenheit sensor
    /// degrades to a data-fitted axis until it reports again. Acceptable — it is the old behaviour,
    /// not a new failure — but it does mean unit detection is not something to rely on elsewhere.
    ///
    /// **The result always contains every point in `series`.** The band is a starting point, never
    /// a clamp: the chart pins its Y scale to this range, so a miscalibrated sensor reading 103%
    /// would otherwise have its line silently clipped at the top of the plot.
    public static func domain(role: UpliftedSensor.Role, unit: String,
                              series: HistorySeries) -> ClosedRange<Double>? {
        guard let band = band(role: role, unit: unit) else {
            return DualAxisScale.domain(for: series)
        }
        guard let lo = series.min, let hi = series.max else { return band.range }
        let lower = min(band.range.lowerBound, floorToStep(lo, band.step))
        let upper = max(band.range.upperBound, ceilToStep(hi, band.step))
        return lower...upper
    }

    /// The tick values for an axis drawn against `domain` with this `step` — every round value the
    /// range covers, ends included. Used for the trailing axis, whose labels this type is
    /// ultimately responsible for.
    public static func ticks(in domain: ClosedRange<Double>, step: Double) -> [Double] {
        guard step > 0, domain.upperBound > domain.lowerBound else { return [domain.lowerBound] }
        let first = ceilToStep(domain.lowerBound, step)
        var values: [Double] = []
        var value = first
        // A tolerance of a tenth of a step, so a bound that is a step multiple in exact arithmetic
        // but a hair over it in binary floating point still yields its final tick.
        while value <= domain.upperBound + step / 10 {
            values.append(value)
            value += step
        }
        return values.isEmpty ? [domain.lowerBound] : values
    }

    private static func floorToStep(_ value: Double, _ step: Double) -> Double {
        (value / step).rounded(.down) * step
    }

    private static func ceilToStep(_ value: Double, _ step: Double) -> Double {
        (value / step).rounded(.up) * step
    }
}
