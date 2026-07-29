import SwiftUI

/// Sizes a sheet to the height of its own content.
///
/// A fixed detent is wrong in *both* directions once a sheet's content varies: a light whose only
/// control is a brightness row leaves two-thirds of a `.medium` sheet empty, while a media player
/// with a source picker has that row clipped off the bottom. These differ in height by a factor of
/// three, so no single fixed detent fits them — the sheet has to measure.
///
/// `.large` stays in the detent set whatever the measurement says, so content taller than
/// `maximum` is always reachable by dragging up, and the sheet always has two sizes to be at.
/// That second part is not cosmetic: SwiftUI draws no drag indicator for a sheet with a single
/// detent and won't let it be dragged, so a one-detent sheet loses its grabber and reads as a
/// full-screen takeover rather than as a sheet.
///
/// **Measuring only works if the content does not end in a `Spacer()`.** A `Spacer` reports
/// whatever height it is offered, so a sheet containing one measures exactly as tall as it already
/// is, and the measurement becomes an elaborate way of changing nothing.
///
/// **Every sheet measures**, including the camera. There used to be an opt-out and a settable
/// initial detent, both for the camera modal alone, on the grounds that a picture reports whatever
/// height it is given. That was not true of the view in question — `CameraModal`'s feed is
/// `.aspectRatio(16/9, contentMode: .fit)`, so its height follows the sheet's fixed width, and it
/// measures to about 405pt on a 6.7" screen where it had been taking the whole 852. Both parameters
/// went with it: a flag with no caller that passes it is a second code path nobody exercises, and
/// the next sheet whose content is genuinely unmeasurable is better served by fixing the content.
///
/// ## Why measure at all, on iOS 26
///
/// `presentationSizing(.fitted)` (iOS 18+) looks like it should make this whole type unnecessary,
/// and on iPad and macOS it would. It sizes a presentation *window*, which is why its siblings are
/// `.form` and `.page` — concepts an iPhone sheet does not have. An iPhone sheet is edge-to-edge
/// and its height comes from its detents, so `presentationDetents` remains the mechanism, and
/// there is still no first-class fit-to-content detent. Measuring the content and handing the
/// result to `.height(_:)` is the current answer, not a workaround for a missing one.
struct FittedSheet: ViewModifier {
    /// A sheet with nothing but a header would otherwise present as a sliver, and a sheet too
    /// short to grab is worse than one slightly too tall.
    static let defaultMinimum: CGFloat = 200
    /// Beyond this the sheet stops growing and its content scrolls instead.
    static let defaultMaximum: CGFloat = 620

    let minimum: CGFloat
    let maximum: CGFloat

    /// The measured height of the content. `nil` until the first layout pass reports one.
    @State private var contentHeight: CGFloat?
    /// Which detent the sheet is at. A *selection*, not a restriction — the set below always
    /// offers `.large` too. It starts at `.medium` and moves onto the measured height as soon as
    /// there is one, which is a single pass and not a visible animation.
    @State private var detent: PresentationDetent = .medium

    init(minimum: CGFloat = FittedSheet.defaultMinimum,
         maximum: CGFloat = FittedSheet.defaultMaximum) {
        self.minimum = minimum
        self.maximum = maximum
    }

    private func clamped(_ height: CGFloat) -> CGFloat { min(max(height, minimum), maximum) }

    /// `[.medium, .large]` only until the first layout pass reports a height — a sheet has to have
    /// detents before anything has been measured, and `.medium` is the least surprising thing to be
    /// for the one frame that lasts.
    private var detents: Set<PresentationDetent> {
        guard let contentHeight else { return [.medium, .large] }
        return [.height(clamped(contentHeight)), .large]
    }

    func body(content: Content) -> some View {
        content
            // Padding first, so the measurement includes it — the sheet has to fit the padded
            // content, not the content alone, or every sheet comes up 32pt short.
            .padding(16)
            // `onGeometryChange` rather than a `GeometryReader` in a `.background`: the reader
            // shape puts a whole extra view behind the content purely to read a number, and needs
            // its own `onChange(of:initial:)` to turn a continuously-available proxy into an
            // event. This states the derived value (`CGFloat`, `Equatable`) directly, so SwiftUI
            // only calls back when the height actually changes.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                // Grow-only: a control that appears and disappears with state (a media player's
                // source row arriving on connect) would otherwise resize the sheet under the
                // user's finger mid-interaction.
                guard height > (contentHeight ?? 0) else { return }
                contentHeight = height
                // Move the selection onto the newly-fitted detent, unless the user has already
                // dragged up to `.large`. `detent` is seeded `.medium`, which stops being a
                // member of `detents` the moment a height is known, and a selection that isn't in
                // the set leaves the sheet at an arbitrary size.
                if detent != .large { detent = .height(clamped(height)) }
            }
            // Still needed even though the sheet is fitted: `maximum` deliberately stops it
            // growing, and `.large` is not unlimited either, so content taller than the screen
            // must remain reachable. `.basedOnSize` keeps short sheets from bouncing as though
            // something were hidden below.
            .modifier(ScrollWhenTall())
            .presentationDetents(detents, selection: $detent)
            // Requested explicitly rather than left to `.automatic`, so every sheet is known to
            // agree rather than agreeing only as long as they all happen to have two detents.
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
    }
}

/// Wraps content in a scroll view that only actually scrolls when it exceeds the space available.
private struct ScrollWhenTall: ViewModifier {
    func body(content: Content) -> some View {
        ScrollView { content }
            .scrollBounceBehavior(.basedOnSize)
    }
}

extension View {
    /// Presents this view as a sheet sized to its own content. See `FittedSheet`.
    func fittedSheet(minimum: CGFloat = FittedSheet.defaultMinimum,
                     maximum: CGFloat = FittedSheet.defaultMaximum) -> some View {
        modifier(FittedSheet(minimum: minimum, maximum: maximum))
    }
}
