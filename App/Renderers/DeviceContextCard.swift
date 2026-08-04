import SwiftUI
import HavenCore

/// What else this device knows.
///
/// A lock says *locked*; whether the door is actually shut is a different entity of the same
/// physical device. This is where those entities get read — `CompositeState` decides which ones and
/// what they say, and this only draws the answer.
///
/// **One card for every domain, added where modals are dispatched rather than inside each of the
/// eleven.** A device gains its context by being a device, not by somebody remembering to add a
/// section to its modal — the same argument `ConfigurableTile` makes about tiles.
///
/// Read-only in this revision. A companion with controls of its own is reachable as a tile by adding
/// it with the `+`, and whether a chime should be ringable from its doorbell's modal is a question
/// about binding, which belongs to 6b.
struct DeviceContextCard: View {
    let entityId: String
    @Environment(HomeStore.self) private var store

    var body: some View {
        let readings = store.deviceState(of: entityId).readings
        // Nothing at all when there are no companions, so every device that has none renders exactly
        // as it did before this existed.
        if !readings.isEmpty {
            FacetCard(title: "Also on this device") {
                VStack(spacing: 8) {
                    ForEach(readings) { reading in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(reading.label)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(reading.value)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                // Tinted only where "active" means something. A battery percentage
                                // is not an alarm and must not be coloured like one — which is why
                                // `DeviceReading.isActive` is optional rather than defaulting false.
                                .foregroundStyle(reading.isActive == true
                                                 ? HavenColor.warning : Color.primary)
                        }
                    }
                }
            }
        }
    }
}
