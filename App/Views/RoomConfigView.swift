import SwiftUI
import HavenCore

/// Which sensors a room's heading reads from.
///
/// Haven nominates one of each the first time it sees a room and writes that down; this is where a
/// user changes it. There is deliberately **no "Automatic" and no "None"**: the auto-pick is
/// first-time priming rather than a mode to return to, so once a room has a nomination it is an
/// ordinary stored value like any other.
struct RoomConfigView: View {
    let areaId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Set when a write fails, so a refusal is explained rather than silently doing nothing. The
    /// sheet deliberately stays open on failure — dismissing would leave the user with a room that
    /// did not change and no reason why.
    @State private var failure: String?

    var body: some View {
        let room = store.rooms().first { $0.areaId == areaId }
        let environment = store.environment[areaId]
        VStack(alignment: .leading, spacing: 12) {
            ModalHeader(systemImage: "thermometer.medium",
                        title: room?.name ?? "Room",
                        subtitle: "Readings shown in this room's heading",
                        accent: HavenColor.domain(.cover), unavailable: false,
                        accessory: AnyView(ModalDoneButton { dismiss() }))
            if let failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(HavenColor.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            role(.temperature, title: "Temperature", environment: environment)
            role(.humidity, title: "Humidity", environment: environment)
            arrangement
        }
    }

    @ViewBuilder
    private func role(_ role: UpliftedSensor.Role, title: String,
                      environment: RoomEnvironment?) -> some View {
        let candidates = environment?.candidates(for: role) ?? []
        FacetCard(title: title) {
            if candidates.isEmpty {
                // Not an error and not a bug: plenty of rooms have no humidity source at all. Saying
                // so is better than an empty card, which reads as a failed load.
                Text("No \(title.lowercased()) sources in this room")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(candidates, id: \.self) { candidate in
                        EntityPickerRow(title: store.displayName(of: candidate.entityId),
                                        entityId: candidate.entityId,
                                        detail: detail(for: candidate),
                                        isSelected: environment?[role] == candidate)
                            .padding(.vertical, 7)
                            // Not a `Button`: in a sheet these fire on the lift at the end of a
                            // scroll — see `TapWithoutDrag`.
                            .tapWithoutDrag { Task { await select(candidate) } }
                    }
                }
            }
        }
    }

    /// **Reset arrangement**, shown only when there is an arrangement to reset.
    ///
    /// It lives with the room's sensor pickers because it is the same kind of thing — a decision
    /// about the room rather than about a device — and it exists because the only other way out of
    /// an arrangement you dislike is to drag your way out of it, which is exactly when dragging is
    /// least appealing.
    @ViewBuilder
    private var arrangement: some View {
        // Either surface having an arrangement is enough to offer the reset, and the reset clears
        // both — see `HomeStore.resetOrder`, which records why clearing one alone would not restore
        // the default at all.
        if !store.config.document.orders(forRoom: areaId).isEmpty {
            FacetCard(title: "Arrangement") {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Reset arrangement") { Task { await resetArrangement() } }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(HavenColor.domain(.cover))
                    Text("Puts this room's tiles back in their default order, here and in the room's own view.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func resetArrangement() async {
        switch await store.resetOrder(areaId: areaId) {
        case .written, .unchanged: failure = nil
        case .notAuthorized: failure = "Only Home Assistant admins can change the household dashboard."
        case .failed: failure = "Couldn't save that. Check your connection and try again."
        }
    }

    /// Names the attribute for an attribute source. Without it a thermostat offering both the room's
    /// temperature and its humidity appears twice, identically — the entity id alone does not say
    /// which reading is meant.
    private func detail(for sensor: UpliftedSensor) -> String? {
        sensor.attributeName.map { "Attribute · \($0)" }
    }

    private func select(_ sensor: UpliftedSensor) async {
        switch await store.nominate(sensor, areaId: areaId) {
        case .written, .unchanged:
            failure = nil
        case .notAuthorized:
            failure = "Only Home Assistant admins can change the household dashboard."
        case .failed:
            failure = "Couldn't save that. Check your connection and try again."
        }
    }
}

#if DEBUG
/// The three shapes that matter: a room with several candidates (two of them called the same thing,
/// which is what the entity id on each row is for), a room whose only source is a thermostat's
/// attribute, and a room with nothing to pick.
private struct RoomConfigPreviewHost: View {
    @State private var store = RoomConfigPreviewHost.populatedStore()
    let areaId: String

    var body: some View {
        RoomConfigView(areaId: areaId).padding(16).environment(store)
    }

    @MainActor
    private static func populatedStore() -> HomeStore {
        let store = HomeStore()
        func set(_ id: String, _ state: String, _ attrs: [String: JSONValue]) {
            store.states[id] = EntityState(entityId: id, state: state, attributes: attrs,
                                           lastUpdated: Date(timeIntervalSince1970: 0))
        }
        set("sensor.lounge_temp", "21.5", ["friendly_name": .string("Lounge Temperature"),
                                           "device_class": .string("temperature"),
                                           "unit_of_measurement": .string("°C")])
        set("sensor.lounge_temp_window", "20.9", ["friendly_name": .string("Temperature"),
                                                  "device_class": .string("temperature"),
                                                  "unit_of_measurement": .string("°C")])
        set("sensor.lounge_hum", "44", ["friendly_name": .string("Lounge Humidity"),
                                        "device_class": .string("humidity"),
                                        "unit_of_measurement": .string("%")])
        set("climate.study", "heat", ["friendly_name": .string("Study Thermostat"),
                                      "current_temperature": .double(19.5),
                                      "temperature": .double(21)])
        store.home = ResolvedHome(floors: [ResolvedFloor(id: "f", name: "Ground", level: 0, areas: [
            ResolvedArea(id: "lounge", name: "Lounge",
                         entityIds: ["sensor.lounge_temp", "sensor.lounge_temp_window",
                                     "sensor.lounge_hum"],
                         tiers: [:]),
            ResolvedArea(id: "study", name: "Study", entityIds: ["climate.study"], tiers: [:]),
            ResolvedArea(id: "hall", name: "Hall", entityIds: [], tiers: [:]),
        ])])
        store.resolveEnvironment()
        return store
    }
}

#Preview("Room config — several candidates") { RoomConfigPreviewHost(areaId: "lounge") }
#Preview("Room config — thermostat attribute only") { RoomConfigPreviewHost(areaId: "study") }
#Preview("Room config — nothing to pick") { RoomConfigPreviewHost(areaId: "hall") }
#endif
