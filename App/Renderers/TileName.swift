import Foundation
import HavenCore

enum TileName {
    static func of(_ entityId: String, _ e: EntityState?) -> String {
        if let n = e?.attributes["friendly_name"]?.asString, !n.isEmpty { return n }
        let obj = String(entityId.drop(while: { $0 != "." }).dropFirst())
        return words(obj)
    }

    /// Renders a raw HA-style snake_case token (`"heat_cool"`, `"kitchen_light"`) for
    /// display: underscores become spaces, then each word is capitalized. Shared by
    /// entity-id-derived names here and by mode/enum strings shown verbatim from HA
    /// (e.g. climate hvac/fan modes), so neither renders "Heat_cool".
    static func words(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
