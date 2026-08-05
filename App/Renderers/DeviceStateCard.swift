import SwiftUI
import HavenCore

/// What Haven works out this device's state to be, and from what.
///
/// **Shown only when Haven derives something the entity itself cannot say.** A plain light's modal
/// gains nothing from a card repeating its own header, so this draws nothing at all unless
/// `DeviceState.face` is non-nil — which today means a garage door with at least one limit bound.
///
/// **The attribution is the point, not decoration.** A relay opener reports `off` while this card
/// says "Partly open", and a household looking at those two facts together deserves to know the
/// second came from their own limit sensors rather than from Haven guessing. It is also the fastest
/// way to spot a sensor bound to the wrong role: the words stop matching the door.
struct DeviceStateCard: View {
    let entityId: String
    @Environment(HomeStore.self) private var store

    var body: some View {
        let state = store.deviceState(of: entityId)
        if let face = state.face {
            FacetCard(title: "State") {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: face.symbol)
                        .font(.system(size: 26))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(state.isActive == true
                                         ? HavenColor.domain(.cover) : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(face.word)
                            .font(.system(size: 19, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        if let from = derivedFrom {
                            Text(from)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// The sensors this reading came from, named as the household named them.
    private var derivedFrom: String? {
        let bound = store.bindings(of: entityId)
        let names = [DeviceRole.closedLimit, .openLimit]
            .compactMap { bound[$0] }
            .map { store.displayName(of: $0) }
        guard !names.isEmpty else { return nil }
        return "From " + names.joined(separator: " and ") + "."
    }
}
