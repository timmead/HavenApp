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
        // The surfaces that want a bigger media tile construct `MediaPlayerTile` directly with the
        // size they intend (see `RoomSectionView`/`RoomDetailView`); this generic dispatcher, which
        // is only ever used inside a 4-column grid, gets the 1×1.
        case .mediaPlayer: MediaPlayerTile(entityId: entityId, size: .small)
        case .scene, .script, .button: SceneTile(entityId: entityId)
        case .sensor: SensorTile(entityId: entityId)
        case .binarySensor: BinarySensorTile(entityId: entityId)
        case .unknown: GenericTile(entityId: entityId)
        }
    }
}
