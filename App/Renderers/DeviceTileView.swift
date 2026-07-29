import SwiftUI
import HavenCore

struct DeviceTileView: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        // Every tile in the grid becomes a configuration target while the dashboard is being
        // edited — see `ConfigurableTile`, which is applied here rather than in each renderer so
        // that a tile added later inherits it by construction.
        tile.configurable(entityId: entityId)
    }

    @ViewBuilder
    private var tile: some View {
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
        // Cameras are **not** meant to arrive here. This dispatcher only ever runs inside a
        // 4-column grid, and the camera renderer has no 1-column size on purpose — below two
        // columns a feed is a thumbnail of a thumbnail. Both surfaces therefore pull cameras out
        // into their own grid before building this one (see `RoomSectionView`/`RoomDetailView`),
        // exactly as they do for climate and media. The 2×2 stands here so the switch is
        // exhaustive and so a future surface that forgets the filter gets a squashed-but-correct
        // tile rather than a `GenericTile` reading "idle" where a picture belongs.
        case .camera: CameraTile(entityId: entityId, size: .square)
        case .scene, .script, .button: SceneTile(entityId: entityId)
        case .sensor: SensorTile(entityId: entityId)
        case .binarySensor: BinarySensorTile(entityId: entityId)
        case .unknown: GenericTile(entityId: entityId)
        }
    }
}
