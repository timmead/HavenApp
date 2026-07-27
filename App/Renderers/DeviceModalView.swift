import SwiftUI
import HavenCore
struct DeviceModalView: View {
    let entityId: String
    @Environment(\.dismiss) private var dismiss

    /// Which detent the sheet is currently at. A *selection*, not a restriction — see `body`.
    ///
    /// Seeded in `init` rather than mutated on appear, so a camera opens large instead of being
    /// presented at medium and then animating upwards, which reads as the sheet twitching.
    @State private var detent: PresentationDetent

    init(entityId: String) {
        self.entityId = entityId
        _detent = State(initialValue: Domain.of(entityId) == .camera ? .large : .medium)
    }

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
        // A camera *opens* straight to `.large`, and every modal offers the same two detents.
        //
        // The reason for the camera's initial size stands: every other modal is a set of controls
        // that fits in half a screen, whereas a camera modal is a picture, and at `.medium` the live
        // view is roughly the size of the tile the user just tapped to get away from. What was wrong
        // was expressing it by handing the camera a *single* detent — SwiftUI draws no drag
        // indicator for a sheet that has only one size to be at, and won't let it be dragged
        // between sizes, so the camera lost its grabber and read as a full-screen takeover rather
        // than as a sheet like every other modal in the app. That was a side effect of the special
        // case, not a decision.
        //
        // Expressed as a *selection* over the same detent set, the camera opens large and still
        // behaves like its siblings: grabber, draggable, dismissible by swipe. The indicator is
        // requested explicitly rather than left to `.automatic` so all eleven modals are known to
        // agree, instead of agreeing only as long as they all happen to have two detents.
        .padding(16)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
    }
}
