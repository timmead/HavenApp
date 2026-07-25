import SwiftUI
import HavenCore

enum HavenColor {
    static func domain(_ d: Domain) -> Color {
        switch d {
        case .light: return Color(red: 0.88, green: 0.63, blue: 0.07)
        case .cover: return Color(red: 0.18, green: 0.44, blue: 0.84)
        case .lock: return Color(red: 0.12, green: 0.62, blue: 0.34)
        case .climate: return Color(red: 0.76, green: 0.25, blue: 0.05)
        case .scene, .script, .button: return Color(red: 0.54, green: 0.36, blue: 0.82)
        case .sensor, .binarySensor, .unknown, .switchOutlet: return Color(red: 0.18, green: 0.44, blue: 0.84)
        }
    }
    static let glassFill = Color.white.opacity(0.55)
    static let glassStroke = Color.white.opacity(0.85)
}
