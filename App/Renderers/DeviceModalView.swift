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

    /// The measured height of the modal's own content, which drives the fitted detent below.
    /// `nil` until the first layout pass reports one.
    @State private var contentHeight: CGFloat?

    /// A modal with nothing but a header would otherwise present as a sliver, and a sheet too
    /// short to grab is worse than one slightly too tall.
    private static let minimumFittedHeight: CGFloat = 200
    /// Beyond this the sheet stops growing and its content scrolls instead. `.large` stays in the
    /// set either way, so tall content is always reachable by dragging up.
    private static let maximumFittedHeight: CGFloat = 620

    init(entityId: String) {
        self.entityId = entityId
        _detent = State(initialValue: Domain.of(entityId) == .camera ? .large : .medium)
    }

    /// The detents this sheet offers. A camera is deliberately excluded from fitted sizing: its
    /// content is a picture that will happily report whatever height it is given, so measuring it
    /// says nothing about how big it *wants* to be.
    private var detents: Set<PresentationDetent> {
        guard Domain.of(entityId) != .camera, let contentHeight else { return [.medium, .large] }
        let fitted = min(max(contentHeight, Self.minimumFittedHeight), Self.maximumFittedHeight)
        return [.height(fitted), .large]
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
        //
        // The sheet is sized to the content rather than pinned at `.medium`, because a fixed
        // detent was wrong in *both* directions: a light whose only control is a brightness row
        // left roughly two-thirds of the sheet empty, while a media player with a source picker
        // had that row clipped off the bottom. Neither is a tuning problem — these modals differ
        // in height by a factor of three, so no single fixed detent can fit them.
        //
        // Measuring only works because the modals no longer end in a `Spacer()`. A `Spacer`
        // reports whatever height it is offered, so every modal would have measured exactly as
        // tall as the sheet already was and the measurement would have been a very elaborate way
        // of changing nothing.
        // Padding first, so the measurement below includes it — the sheet has to fit the padded
        // content, not the content alone, or every modal comes up 32pt short.
        .padding(16)
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                    // Grow-only: a control that appears and disappears with state (a media
                    // player's source row arriving on connect) would otherwise resize the sheet
                    // under the user's finger mid-interaction.
                    guard height > (contentHeight ?? 0) else { return }
                    contentHeight = height
                    // Move the selection onto the newly-fitted detent, unless the user has already
                    // dragged up to `.large` — `detent` is seeded `.medium`, which stops being a
                    // member of `detents` the moment a height is known, and a selection that isn't
                    // in the set leaves the sheet at an arbitrary size.
                    if detent != .large {
                        detent = .height(min(max(height, Self.minimumFittedHeight),
                                             Self.maximumFittedHeight))
                    }
                }
            }
        }
        // The scroll view wraps the *measured* content rather than living inside each modal, which
        // is why the individual modals gave theirs up. A `ScrollView` reports whatever height it is
        // offered, so measuring one tells you the size of the sheet you already have — the modals
        // have to state their ideal height for the detent above to mean anything.
        //
        // It is still needed here: `maximumFittedHeight` deliberately stops the sheet growing, and
        // `.large` is not unlimited either, so content taller than the screen must remain
        // reachable. `.basedOnSize` keeps short modals from bouncing as though something were
        // hidden below.
        .modifier(ScrollWhenTall())
        .presentationDetents(detents, selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
    }
}

/// Wraps content in a scroll view that only actually scrolls when the content exceeds the space.
///
/// Split out as a `ViewModifier` purely so the wrapping happens *around* the measured content in
/// `DeviceModalView.body` without another level of nesting in an already long modifier chain.
private struct ScrollWhenTall: ViewModifier {
    func body(content: Content) -> some View {
        ScrollView { content }
            .scrollBounceBehavior(.basedOnSize)
    }
}
