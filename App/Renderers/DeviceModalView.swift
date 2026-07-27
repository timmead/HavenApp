import SwiftUI
import HavenCore
struct DeviceModalView: View {
    let entityId: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch Domain.of(entityId) {
            case .light: LightModal(entityId: entityId)
            case .switchOutlet: SwitchModal(entityId: entityId)
            case .cover: CoverModal(entityId: entityId)
            case .lock: LockModal(entityId: entityId)
            case .climate: ClimateModal(entityId: entityId)
            case .mediaPlayer: MediaPlayerModal(entityId: entityId)
            case .camera: CameraModal(entityId: entityId)
            case .scene, .script, .button: SceneModal(entityId: entityId)
            case .sensor: SensorModal(entityId: entityId)
            case .binarySensor: BinarySensorModal(entityId: entityId)
            case .unknown: GenericModal(entityId: entityId)
            }
        }
        // A camera *opens* straight to `.large` and is deliberately excluded from fitted sizing:
        // its content is a picture that will happily report whatever height it is given, so
        // measuring it says nothing about how big it *wants* to be. Every other modal measures.
        //
        // The reason for the camera's initial size stands: every other modal is a set of controls
        // that fits in half a screen, whereas a camera modal is a picture, and at `.medium` the
        // live view is roughly the size of the tile the user just tapped to get away from.
        //
        // Expressed as a *selection* over a two-detent set rather than as a single detent, so the
        // camera opens large and still behaves like its siblings: grabber, draggable, dismissible
        // by swipe. See `FittedSheet` for why a one-detent sheet loses its grabber.
        .fittedSheet(measuresContent: Domain.of(entityId) != .camera,
                     initialDetent: Domain.of(entityId) == .camera ? .large : .medium)
    }
}
