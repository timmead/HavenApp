import SwiftUI
import HavenCore

struct DeviceTileView: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        switch Domain.of(entityId) {
        case .light: LightTile(entityId: entityId)
        case .switchOutlet: SwitchTile(entityId: entityId)
        case .cover: CoverTile(entityId: entityId)
        case .lock: LockTile(entityId: entityId)
        case .climate: ClimateTile(entityId: entityId)
        case .scene, .script, .button: SceneTile(entityId: entityId)
        case .sensor: SensorTile(entityId: entityId)
        case .binarySensor: BinarySensorTile(entityId: entityId)
        case .unknown: GenericTile(entityId: entityId)
        }
    }
}
