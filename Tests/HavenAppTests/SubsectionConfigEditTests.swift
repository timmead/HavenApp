import Testing
import HavenCore
@testable import HavenApp

/// `SubsectionConfigEdit` is `SubsectionConfigView`'s dirty-check, extracted so it can be driven
/// directly rather than only through the view's own `private` computed properties — which a test
/// cannot reach at all. It answers exactly what the view's Done button and swipe-to-dismiss both
/// need: what changed, and what `HomeStore.applySubsectionConfig` should be told to write.
@Suite struct SubsectionConfigEditTests {

    /// **The case this type exists to pin.** A surface that is *following* another one (decision
    /// 10's own-then-other-then-default fallback) seeds its draft from the followed value, not from
    /// `nil` — the stored accessor for an unset surface *is* `nil`, but the sheet's draft is
    /// whatever is actually rendering. A regression that compared the draft against the stored value
    /// instead of the seeded one would treat every untouched sheet on a following surface as edited,
    /// and closing it would silently convert the follow into a copy: the surface would stop
    /// following the other one and start carrying its own explicit, identical-for-now value, which
    /// only drifts apart later when the followed surface changes and this one no longer does.
    ///
    /// `TileSpan(columns: 4, rows: 2)` is deliberately not the zero-value default and deliberately
    /// not `nil` — it stands in for a span this surface inherited from the other one, which is
    /// exactly the shape a following surface's seed takes.
    @Test func anUntouchedSheetOnAFollowingSurfaceWritesNothing() {
        let followedSpan = TileSpan(columns: 4, rows: 2)
        let edit = SubsectionConfigEdit(spanIsEditable: true, draftSpan: followedSpan,
                                        seededSpan: followedSpan, draftMode: nil, storedMode: nil)
        #expect(edit.spanEdit == nil)
        #expect(edit.hasChanges == false)
    }

    /// A kind with one size on offer (`.other`) has no Size card at all, so its draft span can never
    /// represent a decision the household made — `spanIsEditable` gates that regardless of whether
    /// `draftSpan` happens to differ from `seededSpan`, which it does here on purpose: if the gate
    /// were missing, this alone would emit an edit.
    @Test func aSingleSpanKindNeverEmitsASpanEdit() {
        let edit = SubsectionConfigEdit(spanIsEditable: false,
                                        draftSpan: TileSpan(columns: 2, rows: 2),
                                        seededSpan: TileSpan(columns: 1, rows: 1),
                                        draftMode: nil, storedMode: nil)
        #expect(edit.spanEdit == nil)
        #expect(edit.hasChanges == false)
    }

    /// The ordinary case: a draft that genuinely differs from what the sheet opened with emits
    /// exactly that new value, explicitly — not collapsed to `nil` even where it might coincide with
    /// a default, per this type's own `spanEdit` doc comment.
    @Test func aChangedSpanEmitsTheNewValueExplicitly() {
        let edit = SubsectionConfigEdit(spanIsEditable: true,
                                        draftSpan: TileSpan(columns: 4, rows: 2),
                                        seededSpan: TileSpan(columns: 2, rows: 2),
                                        draftMode: nil, storedMode: nil)
        #expect(edit.spanEdit == .some(TileSpan(columns: 4, rows: 2)))
        #expect(edit.hasChanges == true)
    }

    /// Choosing "Household default" — the draft mode reading `nil` — is a decision, not an absence
    /// of one, whenever it differs from what was stored. It must emit `.some(nil)`: an explicit
    /// instruction to clear a stored override, not "no edit at all", which is the outer `nil`.
    @Test func choosingHouseholdDefaultOverAStoredOverrideEmitsAnExplicitClear() {
        let edit = SubsectionConfigEdit(spanIsEditable: true,
                                        draftSpan: TileSpan(columns: 1, rows: 1),
                                        seededSpan: TileSpan(columns: 1, rows: 1),
                                        draftMode: nil, storedMode: .wrap)
        #expect(edit.modeEdit == .some(nil))
        #expect(edit.hasChanges == true)
    }

    /// A mode draft that already agrees with what is stored — including the "Household default"
    /// case, both `nil` — reports no edit at all: the outer `nil`, not `.some(nil)`.
    @Test func anUntouchedModeEmitsNoEdit() {
        let edit = SubsectionConfigEdit(spanIsEditable: true,
                                        draftSpan: TileSpan(columns: 1, rows: 1),
                                        seededSpan: TileSpan(columns: 1, rows: 1),
                                        draftMode: .wrap, storedMode: .wrap)
        #expect(edit.modeEdit == nil)
        #expect(edit.hasChanges == false)
    }
}
