import SwiftUI
import HavenCore

/// Which Haven surface the tiles below this point are on.
///
/// **In the environment rather than threaded through every renderer.** A tile needs its surface only
/// to answer one question — what does configuration mode's tap *remove* it from — and eleven tile
/// types each carry two or three gestures that ask it. Passing it as a parameter would mean a new
/// property on all eleven and a new argument at every construction site, to deliver a fact that is
/// constant for a whole grid.
///
/// `ConfigurableTile` sets it, and every tile on either surface is wrapped in that, so the value a
/// tile reads is always the one the grid it lives in declared. The default below therefore never
/// reaches a real dashboard tile; it exists for tiles rendered bare in previews and the gallery,
/// where `.overview` is both true and harmless.
private struct HavenSurfaceKey: EnvironmentKey {
    static let defaultValue: HavenSurface = .overview
}

extension EnvironmentValues {
    var havenSurface: HavenSurface {
        get { self[HavenSurfaceKey.self] }
        set { self[HavenSurfaceKey.self] = newValue }
    }
}
