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

    /// The Recent list's vocabulary, made to match the header's. `HistoryParsing.stateChanges`
    /// drops `unavailable`/`unknown` rows and, for a binary sensor, its raw state is strictly
    /// "on"/"off" — a device class only changes how that reading is displayed, never the string
    /// recorded — so the `on`/`off` branches below are the only ones a real row can hit. Written
    /// as an explicit three-way switch anyway, rather than a bare `state == "on"` ternary: if that
    /// invariant is ever wrong, this falls back to `TileName.words` instead of mislabeling a value
    /// nobody has seen as "Clear".
    private static func label(for state: String) -> String {
        switch state {
        case "on": return "Active"
        case "off": return "Clear"
        default: return TileName.words(state)
        }
    }

    var body: some View {
        let e = store.state(entityId)
        let s = e.map(BinarySensorState.init)
        let active = s?.isActive ?? false
        // `isActive` reads `false` for an `unavailable` state string exactly as it would for a
        // genuinely clear sensor (see `BinarySensorState`), so left alone this header said "Clear"
        // about a door sensor Home Assistant cannot reach — a state claim for an unreachable device,
        // which is this whole branch's thesis to remove. `unavailable` overrides the subtitle and
        // accent the same way `BinarySensorTile` already overrides its icon tint; the icon itself
        // needs no such override, since `IconMap.symbol(domain: .binarySensor, ...)` is the
        // device-class glyph in every state, not an active/clear variant.
        let unavailable = e?.isUnavailable ?? false
        VStack(spacing: 12) {
            ModalHeader(systemImage: IconMap.symbol(domain: .binarySensor, deviceClass: e?.deviceClass),
                        title: TileName.of(entityId, e),
                        subtitle: unavailable ? "Unavailable" : (active ? "Active" : "Clear"),
                        accent: active ? HavenColor.warning : .gray, unavailable: unavailable)

            FacetCard(title: "Recent") {
                if let changes = store.stateChanges(entityId) {
                    if changes.isEmpty {
                        Text("No changes today").font(.caption).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(changes.prefix(Self.maximumChanges), id: \.time) { change in
                                HStack {
                                    // `Self.label(for:)`, not `TileName.words(change.state)` — the
                                    // header two lines above speaks "Active"/"Clear", and rendering
                                    // this list's raw "on"/"off" through a generic word-formatter
                                    // was the same device described in two vocabularies at once.
                                    Text(Self.label(for: change.state))
                                        .font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Text(change.time, format: .dateTime.hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                } else if store.stateChangesLoadFailed(entityId) {
                    // Distinct from both "no changes today" (an empty but successful fetch) and
                    // "not asked yet" below: this fetch was made and it failed. Before this branch
                    // existed, `nil` covered "not asked yet" and "asked and failed" alike, so an
                    // install without the `history` integration — or an entity `recorder` excludes —
                    // showed "Loading…" every time the modal opened, forever.
                    Text("Couldn't load recent changes").font(.caption).foregroundStyle(.secondary)
                } else {
                    // Distinct from "no changes today": we have not asked yet.
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task { await store.loadStateChanges(entityId) }
    }
}
