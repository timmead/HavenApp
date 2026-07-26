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
        case .scene, .script, .button: return Color(red: 0.54, green: 0.36, blue: 0.82)
        case .sensor, .binarySensor, .unknown, .switchOutlet: return Color(red: 0.18, green: 0.44, blue: 0.84)
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
    /// Warm/cool endpoints for the light modal's colour-temperature gradient strip. Deliberately
    /// literal RGB, not a `.primary`-derived token: a 2000K/6500K hue is a semantic fact about
    /// the *light*, not a surface colour, so it must stay the same orange/blue in both light and
    /// dark mode — an "adaptive" version of this pair would be the actual bug.
    static let colorTempWarm = Color(red: 0.95, green: 0.55, blue: 0.16)
    static let colorTempCool = Color(red: 0.42, green: 0.62, blue: 0.95)
}
