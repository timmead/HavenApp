import SwiftUI
import HavenCore

/// A room's temperature and humidity readings, as the small pills the mocks put beside the room
/// name.
///
/// One view rather than the same block written twice: it renders in the room section heading and
/// again in the room detail toolbar, and the two had already drifted into being copies of each
/// other. Which entity each pill reads is decided long before here (`RoomEnvironmentResolver`), and
/// how the number is written is decided in `EnvironmentReading` — this only places them.
struct RoomEnvironmentChips: View {
    let sensors: [UpliftedSensor]
    var spacing: CGFloat = 7
    @Environment(HomeStore.self) private var store

    var body: some View {
        // Keyed by `UpliftedSensor.id`, which is the *role*, not the entity id. A thermostat-only
        // room nominates the same `climate.*` entity for both pills, so keying on the entity id
        // there gives two views the same identity — SwiftUI drops one pill or thrashes view
        // identity. A room has at most one sensor per role, so role is unique by construction.
        HStack(spacing: spacing) {
            ForEach(sensors) { sensor in
                HavenChip(systemImage: symbol(sensor.role),
                          text: EnvironmentReading.display(sensor, state: store.state(sensor.entityId)),
                          accent: accent(sensor.role))
            }
        }
        // Never compress. Collecting the pills into a view of their own — rather than leaving them
        // as loose children of the heading's own `HStack`, which is what they used to be — made
        // them a *single* flexible child of that row, so a tight heading squeezed the whole group
        // and the readings truncated to "6…". A reading is three characters and is the entire point
        // of the pill; the room name is the thing that can afford an ellipsis, and it takes one
        // (`lineLimit(1)` at the call site). This keeps the pills at their natural width so the
        // shortfall lands on the name instead.
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The bulb thermometer rather than a round dial — a nit the design spec calls out by name.
    private func symbol(_ role: UpliftedSensor.Role) -> String {
        role == .temperature ? "thermometer.medium" : "humidity.fill"
    }

    private func accent(_ role: UpliftedSensor.Role) -> Color {
        HavenColor.domain(role == .temperature ? .climate : .cover)
    }
}
