import Foundation
import HavenCore

/// **`of` deliberately no longer exists.** Resolving a name means consulting Haven's own display
/// overrides, which live in `HomeStore.config` — a static function has no way to reach them, and one
/// taking only an `EntityState` would silently render Home Assistant's name for a device the user
/// had renamed. `HomeStore.displayName(of:)` is the only resolver, and this file's *absence* of an
/// `of` is what makes that a grep-checkable invariant rather than a convention.
enum TileName {
    /// Delegates to `DisplayName.words`, which is the same rendering under test in HavenCore.
    /// Kept as a name here because ~10 call sites render HA mode strings (`heat_cool`, `fan_only`)
    /// through it and none of them are about a device's *name*.
    static func words(_ raw: String) -> String { DisplayName.words(raw) }
}
