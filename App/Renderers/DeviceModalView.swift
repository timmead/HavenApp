import SwiftUI
import HavenCore
struct DeviceModalView: View {
    let entityId: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
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
            // Beneath whichever modal was chosen, and measured with it. Both draw nothing at all
            // for an ordinary device — the state card only when Haven derives something the entity
            // cannot say, the context card only when the device has companions.
            //
            // State before companions: what the device *is* outranks what else is attached to it.
            DeviceStateCard(entityId: entityId)
            DeviceContextCard(entityId: entityId)
        }
        // **Every modal measures, cameras included.** The camera used to be excluded and opened
        // straight to `.large`, on the stated grounds that its content is "a picture that will
        // happily report whatever height it is given", which measuring therefore could not size.
        // That was simply not true of this view: `CameraModal`'s feed is
        // `.aspectRatio(16/9, contentMode: .fit)`, so its height is a function of its width, and
        // the sheet's width is fixed. It measures like anything else — and it turns out to want
        // roughly half a screen, which is what a full-screen takeover was hiding.
        //
        // What was true is that a `.medium` camera is barely bigger than the tile you tapped to get
        // away from. Fitted sizing answers that better than `.large` did: the sheet is exactly its
        // content, so the feed is as large as the feed needs, and `.large` remains in the detent set
        // for anyone who wants to drag it up.
        .fittedSheet()
    }
}
