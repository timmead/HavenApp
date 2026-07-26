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
            case .scene, .script, .button: SceneModal(entityId: entityId)
            case .sensor: SensorModal(entityId: entityId)
            case .binarySensor: BinarySensorModal(entityId: entityId)
            case .unknown: GenericModal(entityId: entityId)
            }
        }
        .padding(16).presentationDetents([.medium, .large]).presentationBackground(.regularMaterial)
    }
}
