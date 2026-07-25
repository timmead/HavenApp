import Foundation
import HavenCore

enum TileName {
    static func of(_ entityId: String, _ e: EntityState?) -> String {
        if let n = e?.attributes["friendly_name"]?.asString, !n.isEmpty { return n }
        let obj = String(entityId.drop(while: { $0 != "." }).dropFirst())
        return obj.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
