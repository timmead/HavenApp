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
        // A camera opens straight to `.large`. Every other modal is a set of controls that fits in
        // half a screen, whereas a camera modal *is* a picture — at `.medium` the live view is
        // roughly tile-sized, which is the size the user just tapped to get away from.
        .padding(16)
        .presentationDetents(Domain.of(entityId) == .camera ? [.large] : [.medium, .large])
        .presentationBackground(.regularMaterial)
    }
}
