import Foundation
import HavenCore

enum TileName {
    static func of(_ entityId: String, _ e: EntityState?) -> String {
        if let n = e?.attributes["friendly_name"]?.asString, !n.isEmpty { return n }
        let obj = String(entityId.drop(while: { $0 != "." }).dropFirst())
        return words(obj)
    }

    /// Delegates to `DisplayName.words`, which is the same rendering under test in HavenCore.
    /// Kept as a name here because ~10 call sites render HA mode strings (`heat_cool`, `fan_only`)
    /// through it and none of them are about a device's *name*.
    static func words(_ raw: String) -> String { DisplayName.words(raw) }
}
