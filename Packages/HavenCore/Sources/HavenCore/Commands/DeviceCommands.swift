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
    func activate(sceneOrScript id: String) async throws {
        let d = Domain.serviceDomain(of: id)          // "scene" | "script" | "button" | "input_button" | ...
        let isButton = (d == "button" || d == "input_button")
        try await call(d, isButton ? "press" : "turn_on", id)
    }
}
