import Foundation

public extension HomeConnection {
    private func call(_ domain: String, _ service: String, _ entityId: String, _ data: [String: JSONValue] = [:]) async throws {
        _ = try await client.request { WSCommand.callService(id: $0, domain: domain, service: service, entityId: entityId, serviceData: data) }
    }
    func callServiceRaw(domain: String, service: String, entityId: String, data: [String: JSONValue] = [:]) async throws { try await call(domain, service, entityId, data) }

    func setLight(_ id: String, on: Bool) async throws { try await call("light", on ? "turn_on" : "turn_off", id) }
    func setBrightness(_ id: String, percent: Int) async throws { try await call("light", "turn_on", id, ["brightness_pct": .int(max(0, min(100, percent)))]) }
    func setColorTemp(_ id: String, kelvin: Int) async throws { try await call("light", "turn_on", id, ["color_temp_kelvin": .int(kelvin)]) }
    func setSwitch(_ id: String, on: Bool) async throws { try await call(Domain.serviceDomain(of: id), on ? "turn_on" : "turn_off", id) }
    func openCover(_ id: String) async throws { try await call("cover", "open_cover", id) }
    func closeCover(_ id: String) async throws { try await call("cover", "close_cover", id) }
    func stopCover(_ id: String) async throws { try await call("cover", "stop_cover", id) }
    func setCoverPosition(_ id: String, percent: Int) async throws { try await call("cover", "set_cover_position", id, ["position": .int(max(0, min(100, percent)))]) }
    func setLock(_ id: String, locked: Bool) async throws { try await call("lock", locked ? "lock" : "unlock", id) }
    func setClimateMode(_ id: String, mode: String) async throws { try await call("climate", "set_hvac_mode", id, ["hvac_mode": .string(mode)]) }
    func setClimateTemp(_ id: String, temp: Double) async throws { try await call("climate", "set_temperature", id, ["temperature": .double(temp)]) }
    func setFanMode(_ id: String, mode: String) async throws { try await call("climate", "set_fan_mode", id, ["fan_mode": .string(mode)]) }
    // MARK: - Media player
    //
    // Every one of these derives its service domain from the entity-id prefix rather than from a
    // renderer enum, for the reason recorded in D spec §10a: Home Assistant answers *success* to a
    // call on the wrong domain and does nothing, so the mistake is invisible.
    //
    // `media_play`/`media_pause` are sent explicitly rather than `media_play_pause`. The caller
    // already knows which way it is going (it has just written the optimistic state), and the two
    // services map one-to-one onto the two `supported_features` bits the button is gated on — a
    // toggle service would be one call covering two separately-declared capabilities.

    func mediaPlay(_ id: String) async throws { try await call(Domain.serviceDomain(of: id), "media_play", id) }
    func mediaPause(_ id: String) async throws { try await call(Domain.serviceDomain(of: id), "media_pause", id) }
    func mediaNextTrack(_ id: String) async throws { try await call(Domain.serviceDomain(of: id), "media_next_track", id) }
    func mediaPreviousTrack(_ id: String) async throws { try await call(Domain.serviceDomain(of: id), "media_previous_track", id) }
    /// Percent in, `volume_level` (0…1) out — Home Assistant's own unit, and the same conversion
    /// `MediaPlayerState.volumePercent` reads back.
    func setMediaVolume(_ id: String, percent: Int) async throws {
        try await call(Domain.serviceDomain(of: id), "volume_set", id,
                       ["volume_level": .double(Double(max(0, min(100, percent))) / 100)])
    }
    func setMediaMuted(_ id: String, muted: Bool) async throws {
        try await call(Domain.serviceDomain(of: id), "volume_mute", id, ["is_volume_muted": .bool(muted)])
    }
    func selectMediaSource(_ id: String, source: String) async throws {
        try await call(Domain.serviceDomain(of: id), "select_source", id, ["source": .string(source)])
    }
    /// Power, never play/pause — see `MediaPlayerFeatures.supportsPower` for when it may be offered.
    func setMediaPower(_ id: String, on: Bool) async throws {
        try await call(Domain.serviceDomain(of: id), on ? "turn_on" : "turn_off", id)
    }

    func activate(sceneOrScript id: String) async throws {
        let d = Domain.serviceDomain(of: id)          // "scene" | "script" | "button" | "input_button" | ...
        let isButton = (d == "button" || d == "input_button")
        try await call(d, isButton ? "press" : "turn_on", id)
    }
}
