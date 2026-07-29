import SwiftUI
import HavenCore

/// A device's configuration. Today: what it is called.
///
/// The name is **Haven's own**, never a rename of the Home Assistant entity — HA stays the source of
/// truth for structure and Haven layers on top. That has a consequence this sheet is obliged to make
/// visible: an override shadows HA permanently, so renaming the entity in Home Assistant afterwards
/// will not show up here. Hence the line naming what HA calls the device, and the reset beside it.
///
/// Sub-project 3 adds removal to this sheet; sub-project 6 adds which entities feed a tile.
struct TileConfigView: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// The field's live text. Seeded once from the current *override* — deliberately not bound
    /// straight through to the store, which would write on every keystroke.
    @State private var draft: String = ""
    @State private var failure: String?

    private var storedOverride: String? { store.config.document.displayNames[entityId] }

    var body: some View {
        let e = store.state(entityId)
        let haName = e?.attributes["friendly_name"]?.asString
        VStack(alignment: .leading, spacing: 12) {
            ModalHeader(systemImage: IconMap.symbol(domain: Domain.of(entityId),
                                                    deviceClass: e?.deviceClass),
                        title: store.displayName(of: entityId),
                        subtitle: entityId,
                        accent: HavenColor.domain(Domain.of(entityId)), unavailable: false)
            FacetCard(title: "Name") {
                VStack(alignment: .leading, spacing: 9) {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)
                        .onSubmit { Task { await write(draft) } }
                    // What Home Assistant calls it, so an override reads as an override rather than
                    // as a mystery — and so the user can see what a reset would give them back.
                    Text(haName.map { "Home Assistant calls this “\($0)”" }
                         ?? "Home Assistant has no name for this device")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if let failure {
                        Text(failure).font(.system(size: 12)).foregroundStyle(HavenColor.warning)
                    }
                    HStack {
                        if storedOverride != nil {
                            Button("Reset to Home Assistant's name") { Task { await write(nil) } }
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Spacer(minLength: 8)
                        Button("Save") { Task { await write(draft) } }
                            .font(.system(size: 13, weight: .bold))
                            .disabled(!hasChanges)
                    }
                }
            }
        }
        // Seeded from the *override*, not from the resolved name: pre-filling with Home Assistant's
        // name would turn every "let me look at this device" into a rename the moment the user hit
        // Save, and the household would fill up with overrides nobody chose.
        .onAppear { draft = storedOverride ?? "" }
    }

    /// Whether Save would change anything. Compared against the stored override rather than against
    /// the resolved name, and trimmed, so re-typing the same name with a stray space is not an edit.
    private var hasChanges: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines) != (storedOverride ?? "")
    }

    private func write(_ name: String?) async {
        switch await store.rename(entityId, to: name) {
        case .written, .unchanged:
            dismiss()
        case .notAuthorized:
            failure = "Only Home Assistant admins can change the household dashboard."
        case .failed:
            failure = "Couldn't save that. Check your connection and try again."
        }
    }
}

#if DEBUG
private struct TileConfigPreviewHost: View {
    let entityId: String
    @State private var store: HomeStore

    init(entityId: String, overridden: Bool) {
        self.entityId = entityId
        _store = State(initialValue: TileConfigPreviewHost.populatedStore(overridden: overridden))
    }

    var body: some View {
        TileConfigView(entityId: entityId).padding(16).environment(store)
    }

    @MainActor
    private static func populatedStore(overridden: Bool) -> HomeStore {
        let store = HomeStore()
        store.states["light.kitchen"] = EntityState(
            entityId: "light.kitchen", state: "on",
            attributes: ["friendly_name": .string("Kitchen Light")],
            lastUpdated: Date(timeIntervalSince1970: 0))
        if overridden {
            store.config.seedForTesting(
                DashboardDocument().settingDisplayName("Reading Lamp", for: "light.kitchen"))
        }
        return store
    }
}

/// The field is pre-filled only in the renamed case — a device you have merely opened must not
/// arrive holding Home Assistant's name, or Save silently converts it into an override.
#Preview("Tile config — renamed") { TileConfigPreviewHost(entityId: "light.kitchen", overridden: true) }
#Preview("Tile config — not renamed") { TileConfigPreviewHost(entityId: "light.kitchen", overridden: false) }
#endif
