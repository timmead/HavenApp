import SwiftUI
import HavenCore

/// What this surface could show and isn't.
///
/// **No checkmarks**, unlike the room's sensor picker: nothing in this list is currently selected —
/// that is exactly what makes it addable — so a column of empty checkmark slots would be furniture
/// suggesting a state that cannot occur here. Tapping adds and dismisses.
struct AddTileView: View {
    let areaId: String
    let surface: HavenSurface
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Set when a write fails, so a refusal is explained rather than the sheet appearing to ignore a
    /// tap. The sheet stays open on failure for the same reason.
    @State private var failure: String?

    var body: some View {
        let room = store.rooms().first { $0.areaId == areaId }
        let addable = room.map { store.addableEntityIds(in: $0, on: surface) } ?? []
        VStack(alignment: .leading, spacing: 12) {
            ModalHeader(systemImage: "plus.circle",
                        title: "Add to \(room?.name ?? "room")",
                        subtitle: subtitle,
                        accent: HavenColor.domain(.cover), unavailable: false,
                        accessory: AnyView(ModalDoneButton { dismiss() }))
            if let failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(HavenColor.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            FacetCard {
                if addable.isEmpty {
                    // Not an error: a room can genuinely be showing everything it has. Saying so
                    // beats an empty card, which reads as a failed load.
                    Text("Everything in this room is already here.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(addable, id: \.self) { entityId in
                            Button {
                                Task { await add(entityId) }
                            } label: {
                                EntityPickerRow(title: store.displayName(of: entityId),
                                                entityId: entityId,
                                                isSelected: false)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 7)
                        }
                    }
                }
            }
        }
    }

    private var subtitle: String {
        switch surface {
        case .overview: return "In this room, but not on the dashboard"
        case .roomDetail: return "In this room, but not shown here"
        }
    }

    private func add(_ entityId: String) async {
        switch await store.setMembership(entityId, on: surface, to: .shown) {
        case .written, .unchanged: dismiss()
        case .notAuthorized: failure = "Only Home Assistant admins can change the household dashboard."
        case .failed: failure = "Couldn't save that. Check your connection and try again."
        }
    }
}

#if DEBUG
/// Two shapes: a room with something to add, and one already showing everything it has.
private struct AddTilePreviewHost: View {
    @State private var store = AddTilePreviewHost.populatedStore()
    let areaId: String

    var body: some View {
        AddTileView(areaId: areaId, surface: .overview).padding(16).environment(store)
    }

    @MainActor
    private static func populatedStore() -> HomeStore {
        let store = HomeStore()
        func set(_ id: String, _ state: String, _ attrs: [String: JSONValue]) {
            store.states[id] = EntityState(entityId: id, state: state, attributes: attrs,
                                           lastUpdated: Date(timeIntervalSince1970: 0))
        }
        set("light.lounge", "on", ["friendly_name": .string("Lounge Ceiling")])
        // `.secondary` by curation, so the dashboard is not showing it — exactly an addable candidate.
        set("sensor.lounge_power", "412", ["friendly_name": .string("Lounge Power"),
                                           "device_class": .string("power"),
                                           "unit_of_measurement": .string("W")])
        set("light.study", "off", ["friendly_name": .string("Study Lamp")])
        store.home = ResolvedHome(floors: [ResolvedFloor(id: "f", name: "Ground", level: 0, areas: [
            ResolvedArea(id: "lounge", name: "Lounge",
                         entityIds: ["light.lounge", "sensor.lounge_power"],
                         tiers: ["light.lounge": .primary, "sensor.lounge_power": .secondary]),
            // Everything it has is already a dashboard tile.
            ResolvedArea(id: "study", name: "Study", entityIds: ["light.study"],
                         tiers: ["light.study": .primary]),
        ])])
        return store
    }
}

#Preview("Add tile — something to add") { AddTilePreviewHost(areaId: "lounge") }
#Preview("Add tile — nothing to add") { AddTilePreviewHost(areaId: "study") }

/// The sheet **over content**, which is the only way to see that its background is opaque. The
/// configuration foundation shipped a translucent banner precisely because every check of it was a
/// render at rest, where nothing sits behind.
#Preview("Add tile — over content") {
    ZStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 0) {
            Text("Driveway").font(.system(size: 17, weight: .bold))
            Rectangle().fill(.orange).frame(height: 200)
        }
        AddTilePreviewHost(areaId: "lounge")
            .background(.background)
    }
}
#endif
