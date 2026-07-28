import SwiftUI
import HavenCore

/// Current state, plus what it has been doing today.
///
/// Shipped as a header alone through subproject D — the one renderer whose modal was never
/// finished. The spec's §4 row asks for "current state + recent changes (deep timeline = later)",
/// so this is a short list of transitions, not a scrubable chart.
struct BinarySensorModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store

    /// Enough to answer "has this been going off all day?" without becoming the timeline the spec
    /// defers.
    private static let maximumChanges = 10

    var body: some View {
        let e = store.state(entityId)
        let s = e.map(BinarySensorState.init)
        let active = s?.isActive ?? false
        VStack(spacing: 12) {
            ModalHeader(systemImage: IconMap.symbol(domain: .binarySensor, deviceClass: e?.deviceClass),
                        title: TileName.of(entityId, e),
                        subtitle: active ? "Active" : "Clear",
                        accent: active ? HavenColor.warning : .gray)

            FacetCard(title: "Recent") {
                if let changes = store.stateChanges(entityId) {
                    if changes.isEmpty {
                        Text("No changes today").font(.caption).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(changes.prefix(Self.maximumChanges), id: \.time) { change in
                                HStack {
                                    Text(TileName.words(change.state))
                                        .font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Text(change.time, format: .dateTime.hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                } else {
                    // Distinct from "no changes today": we have not asked yet.
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task { await store.loadStateChanges(entityId) }
    }
}
