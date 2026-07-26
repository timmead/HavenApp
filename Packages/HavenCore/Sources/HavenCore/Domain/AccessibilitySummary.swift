import Foundation

/// Builds the one spoken sentence a tile or modal control uses for its `accessibilityLabel`.
/// Today state is conveyed largely by colour (an amber "on" tint, a warning-coloured jam icon),
/// which a VoiceOver user can't see — these strings are what carry the same information as
/// text: what the thing is, whether it's on, and its live value, e.g. "Kitchen light, on, 60%
/// brightness". Callers pass in the already-resolved display name (`TileName.of(...)`, an
/// App-layer concern) and the typed domain state; this stays in HavenCore only because the
/// value-formatting logic (percent, temperature, mode text) is the same logic already unit
/// tested per-domain, not because the name-resolution belongs here.
public enum AccessibilitySummary {
    public static func light(_ name: String, _ s: LightState) -> String {
        guard s.isOn else { return "\(name), off" }
        guard let pct = s.brightnessPercent else { return "\(name), on" }
        return "\(name), on, \(pct)% brightness"
    }

    public static func switchOutlet(_ name: String, isOn: Bool) -> String {
        "\(name), \(isOn ? "on" : "off")"
    }

    public static func cover(_ name: String, _ s: CoverState) -> String {
        let state = s.isOpen ? "open" : "closed"
        guard let pos = s.positionPercent else { return "\(name), \(state)" }
        return "\(name), \(state), \(pos)% open"
    }

    public static func lock(_ name: String, _ s: LockState) -> String {
        if s.isJammed { return "\(name), jammed" }
        return "\(name), \(s.isLocked ? "locked" : "unlocked")"
    }

    public static func climate(_ name: String, _ s: ClimateState) -> String {
        guard s.isOn else { return "\(name), off" }
        let mode = s.hvacMode.replacingOccurrences(of: "_", with: " ")
        guard let target = s.targetTemp else { return "\(name), \(mode)" }
        return "\(name), \(mode), target \(Int(target.rounded()))\(s.unit)"
    }

    /// "Kitchen speaker, playing, So What by Miles Davis". State first (a VoiceOver user gets no
    /// benefit from the accent colour that says it to everyone else), then what is playing, then
    /// the volume — which is otherwise legible only from a slider's fill.
    public static func mediaPlayer(_ name: String, _ s: MediaPlayerState) -> String {
        guard s.isActive else { return "\(name), \(s.playback.label.lowercased())" }
        var parts = ["\(name), \(s.playback.label.lowercased())"]
        if let title = s.title {
            parts.append(s.secondaryLine.map { "\(title) by \($0)" } ?? title)
        } else {
            parts.append("nothing playing")
        }
        if s.isMuted { parts.append("muted") }
        else if let volume = s.volumePercent { parts.append("volume \(volume)%") }
        return parts.joined(separator: ", ")
    }

    public static func binarySensor(_ name: String, _ s: BinarySensorState) -> String {
        "\(name), \(s.isActive ? "active" : "clear")"
    }

    public static func sensor(_ name: String, _ s: SensorState) -> String {
        guard let unit = s.unit, !unit.isEmpty else { return "\(name), \(s.value)" }
        return "\(name), \(s.value) \(unit)"
    }

    public static func scene(_ name: String) -> String { "\(name), scene" }

    /// Fallback for entities with no typed domain model (`GenericTile`/`GenericModal`) —
    /// speaks HA's raw state string, which is all the app itself knows about them.
    public static func generic(_ name: String, rawState: String) -> String {
        "\(name), \(rawState)"
    }
}
