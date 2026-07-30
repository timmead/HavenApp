import SwiftUI
import HavenCore

enum HavenColor {
    static func domain(_ d: Domain) -> Color {
        switch d {
        case .light: return Color(red: 0.88, green: 0.63, blue: 0.07)
        case .cover: return Color(red: 0.18, green: 0.44, blue: 0.84)
        case .lock: return Color(red: 0.12, green: 0.62, blue: 0.34)
        case .climate: return Color(red: 0.76, green: 0.25, blue: 0.05)
        case .mediaPlayer: return Color(red: 0.05, green: 0.52, blue: 0.56)
        case .camera: return Color(red: 0.36, green: 0.30, blue: 0.62)
        case .scene, .script, .button: return Color(red: 0.54, green: 0.36, blue: 0.82)
        case .sensor, .binarySensor, .unknown, .switchOutlet: return Color(red: 0.18, green: 0.44, blue: 0.84)
        }
    }
    /// A thermostat's colour, by what it is doing — heating red, cooling blue, fan green, drying
    /// purple.
    ///
    /// The one domain whose single accent was not enough. Every other domain has one job; a
    /// thermostat has four, and "the climate colour" made a room being cooled to 19° look exactly
    /// like one being heated to 21° — the difference a glance at a dashboard is *for*.
    ///
    /// `.unspecified` keeps `domain(.climate)`, which is the honest answer for `heat_cool`, `auto`
    /// and `off`: a thermostat that will do either and is currently doing neither has no true
    /// colour, and picking one would be a claim about the house. Which function a thermostat has is
    /// `ClimateState.function`'s decision, in HavenCore with tests, because it is a reading of Home
    /// Assistant's vocabulary and not a matter of taste.
    ///
    /// Literal RGB and the same in both appearances, on the same footing as `liveIndicator` and the
    /// colour-temperature pair: warm-means-heating is a fact about the equipment, not a surface
    /// tint, and a `.primary`-derived version would render two of these as the same grey.
    static func climate(_ function: ClimateState.Function) -> Color {
        switch function {
        case .heat: return Color(red: 0.84, green: 0.21, blue: 0.13)
        case .cool: return Color(red: 0.13, green: 0.47, blue: 0.86)
        case .fan: return Color(red: 0.11, green: 0.60, blue: 0.36)
        case .dry: return Color(red: 0.55, green: 0.29, blue: 0.78)
        case .unspecified: return domain(.climate)
        }
    }

    /// Subtle translucent fill for glass surfaces — adapts to light/dark.
    static let glassFill = Color.primary.opacity(0.06)
    /// Hairline edge for glass surfaces — adapts to light/dark.
    static let glassStroke = Color.primary.opacity(0.12)
    /// Track fill behind a `LevelBar`'s filled portion — adapts to light/dark (a hardcoded
    /// black track is invisible against a dark background).
    static let levelTrack = Color.primary.opacity(0.09)
    /// Shared "warning/attention" semantic (jammed lock, active binary-sensor alert, etc.) —
    /// one amber token instead of each call site inventing its own.
    static let warning = Color(red: 0.85, green: 0.40, blue: 0.05)
    /// Destructive actions — today, removing a tile from a surface.
    ///
    /// Its own token rather than `Color.red`, so the app's one destructive control has one colour
    /// wherever it appears; and deliberately not `warning`, which is amber and already means "this
    /// needs your attention" on a jammed lock and an active sensor. A colour that meant both would
    /// mean neither.
    static let destructive = Color(red: 0.84, green: 0.19, blue: 0.19)
    /// The camera modal's live indicator. Deliberately literal RGB and deliberately the same in
    /// both appearances, on the same footing as the colour-temperature pair below: "this feed is
    /// live right now" is a universally-read red, not a surface tint, and a `.primary`-derived
    /// token would render it as an ordinary grey dot in light mode — a live indicator that doesn't
    /// indicate. It is the *only* visible colour carrying that meaning, which is why the same fact
    /// is also spoken as text (see `CameraModal`'s live dot).
    static let liveIndicator = Color(red: 0.90, green: 0.19, blue: 0.20)
    /// Warm/cool endpoints for the light modal's colour-temperature gradient strip. Deliberately
    /// literal RGB, not a `.primary`-derived token: a 2000K/6500K hue is a semantic fact about
    /// the *light*, not a surface colour, so it must stay the same orange/blue in both light and
    /// dark mode — an "adaptive" version of this pair would be the actual bug.
    static let colorTempWarm = Color(red: 0.95, green: 0.55, blue: 0.16)
    static let colorTempCool = Color(red: 0.42, green: 0.62, blue: 0.95)
}
