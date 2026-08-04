import Foundation

/// What a device is called, in one place.
///
/// Three rungs, highest first:
///
/// 1. **Haven's own override** — what the user typed in configuration mode.
/// 2. **Home Assistant's `friendly_name`.**
/// 3. **The entity id**, rendered as words.
///
/// The override outranking Home Assistant is the deliberate part, and it has a consequence worth
/// naming: renaming the entity in HA afterwards will *not* show up in Haven. An explicit choice
/// outranks a default, which is the right precedence — and it is why the rename sheet shows what HA
/// calls the device underneath, so an override reads as an override rather than as a mystery.
///
/// A rule rather than a chain inside a view, because the whole app has to agree on it: tiles,
/// modals, accessibility labels, and every picker row. It was previously three lines inside
/// `TileName.of` that no test could reach.
public enum DisplayName {
    /// The name to show. `override` and `friendlyName` are both treated as absent when blank —
    /// clearing the rename field must reset to Home Assistant's name, not render an empty tile,
    /// and HA itself can carry `friendly_name` as an empty string.
    public static func resolve(override: String?, friendlyName: String?, entityId: String) -> String {
        if let override = present(override) { return override }
        if let friendly = present(friendlyName) { return friendly }
        return words(String(entityId.drop(while: { $0 != "." }).dropFirst()))
    }

    /// Renders a raw HA-style snake_case token (`"heat_cool"`, `"kitchen_light"`) for display:
    /// underscores become spaces, then each word is capitalized. Shared by the entity-id rung above
    /// and by mode/enum strings shown verbatim from HA (climate hvac/fan modes), so neither renders
    /// "Heat_cool".
    public static func words(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// What a typed draft becomes when stored: trimmed, and `nil` when that leaves nothing.
    ///
    /// **The same rule `resolve` already applies when reading, stated once for writing**, so the two
    /// cannot drift. The configuration sheet's field starts empty for a device nobody has renamed, so
    /// `""` has to mean "no override" rather than an override *to* nothing — which would shadow Home
    /// Assistant's name with a blank caption, and read as a broken tile rather than an unnamed one.
    public static func override(from draft: String) -> String? {
        present(draft)
    }

    private static func present(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
