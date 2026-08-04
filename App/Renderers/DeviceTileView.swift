import SwiftUI
import HavenCore

struct DeviceTileView: View {
    let entityId: String
    /// The surface this grid *is*. Explicit for the reason `ConfigurableTile.surface` is.
    let surface: HavenSurface
    /// How many cells this tile was given, which is what decides *which* rendering it gets.
    ///
    /// **Passed in rather than looked up**, because the caller is the grid that placed it: a tile
    /// drawing at a size other than the one it occupies either overflows its cell or rattles around
    /// inside it. Defaulted to the surface's own default, so the call sites with no opinion do not
    /// have to state one.
    var span: TileSpan?
    @Environment(HomeStore.self) private var store

    private var resolvedSpan: TileSpan {
        span ?? TileSpan.default(for: Domain.of(entityId), on: surface)
    }
    var body: some View {
        // Every tile in the grid becomes a configuration target while the dashboard is being
        // edited — see `ConfigurableTile`, which is applied here rather than in each renderer so
        // that a tile added later inherits it by construction.
        tile.configurable(entityId: entityId, on: surface)
    }

    /// **The one place a span becomes a rendering.**
    ///
    /// Both surfaces used to construct the bigger tiles themselves — `MediaPlayerTile(size: .wide)`
    /// on the dashboard, `.large` in room detail, and the two camera sizes likewise — while
    /// `TileSpan.default` separately said how many cells those tiles occupy. Two encodings of one
    /// fact, agreeing by hand. Here they agree by construction: the span decides the rendering, so a
    /// tile cannot be given four columns and drawn as though it had two.
    ///
    /// A span with no rendering falls back to the domain's smallest rather than refusing to draw. A
    /// stored size that no longer exists is still a device the household owns, and it has to appear.
    @ViewBuilder
    private var tile: some View {
        let span = resolvedSpan
        switch Domain.of(entityId) {
        case .light: LightTile(entityId: entityId)
        case .switchOutlet: SwitchTile(entityId: entityId)
        case .cover: CoverTile(entityId: entityId)
        case .lock: LockTile(entityId: entityId)
        case .climate: ClimateTile(entityId: entityId, size: ClimateTileSize(span: span))
        case .mediaPlayer:
            MediaPlayerTile(entityId: entityId, size: MediaTileSize(span: span))
        case .camera:
            CameraTile(entityId: entityId, size: CameraTileSize(span: span))
        case .scene, .script, .button: SceneTile(entityId: entityId)
        case .sensor: SensorTile(entityId: entityId, size: SensorTileSize(span: span))
        case .binarySensor: BinarySensorTile(entityId: entityId)
        case .unknown: GenericTile(entityId: entityId)
        }
    }
}
