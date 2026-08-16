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
                                        seededSpan: followedSpan, storedSpan: nil,
                                        draftMode: nil, storedMode: nil)
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
                                        seededSpan: TileSpan(columns: 1, rows: 1), storedSpan: nil,
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
                                        storedSpan: TileSpan(columns: 2, rows: 2),
                                        draftMode: nil, storedMode: nil)
        #expect(edit.spanEdit == .some(TileSpan(columns: 4, rows: 2)))
        #expect(edit.hasChanges == true)
    }

    /// **The follow-up this type gained a representation for**: picking "Follow" on a surface that
    /// currently carries its own explicit span (`storedSpan` non-`nil`) is a real decision, and must
    /// emit `.some(nil)` — the clear `settingSubsectionSpan` needs to hand the surface back to the
    /// fallback chain. `draftSpan: nil` is the sheet's representation of "Follow was chosen"; it is
    /// never a value `seededSpan` or `storedSpan` can hold, so it cannot be confused with either.
    @Test func chosingFollowOnAConfiguredSurfaceEmitsAnExplicitClear() {
        let ownSpan = TileSpan(columns: 2, rows: 2)
        let edit = SubsectionConfigEdit(spanIsEditable: true, draftSpan: nil,
                                        seededSpan: ownSpan, storedSpan: ownSpan,
                                        draftMode: nil, storedMode: nil)
        #expect(edit.spanEdit == .some(nil))
        #expect(edit.hasChanges == true)
    }

    /// **The no-op this type must also get right.** A surface with no explicit span of its own is
    /// already following — `storedSpan == nil` — so choosing "Follow" there (however that draft state
    /// arose) has nothing to clear. Emitting `.some(nil)` regardless would still be correct on the
    /// wire (clearing an absent key is a no-op there too) but would cost the shared document a version
    /// bump for a sheet that changed nothing, exactly the churn `seededSpan` above exists to prevent
    /// for the ordinary case.
    @Test func choosingFollowWhenAlreadyFollowingEmitsNoEdit() {
        let resolvedSpan = TileSpan(columns: 4, rows: 2)  // whatever this surface renders already
        let edit = SubsectionConfigEdit(spanIsEditable: true, draftSpan: nil,
                                        seededSpan: resolvedSpan, storedSpan: nil,
                                        draftMode: nil, storedMode: nil)
        #expect(edit.spanEdit == nil)
        #expect(edit.hasChanges == false)
    }

    /// **Picking a concrete size back out of Follow** takes the same path an ordinary change does —
    /// compared against `seededSpan`, not `storedSpan` — so a sheet that visits Follow and then picks
    /// a size still writes exactly the size chosen, regardless of what the surface started with.
    @Test func pickingASpanAfterFollowEmitsThatSpanExplicitly() {
        let edit = SubsectionConfigEdit(spanIsEditable: true,
                                        draftSpan: TileSpan(columns: 1, rows: 1),
                                        seededSpan: TileSpan(columns: 4, rows: 2), storedSpan: nil,
                                        draftMode: nil, storedMode: nil)
        #expect(edit.spanEdit == .some(TileSpan(columns: 1, rows: 1)))
        #expect(edit.hasChanges == true)
    }

    /// Choosing "Household default" — the draft mode reading `nil` — is a decision, not an absence
    /// of one, whenever it differs from what was stored. It must emit `.some(nil)`: an explicit
    /// instruction to clear a stored override, not "no edit at all", which is the outer `nil`.
    @Test func choosingHouseholdDefaultOverAStoredOverrideEmitsAnExplicitClear() {
        let edit = SubsectionConfigEdit(spanIsEditable: true,
                                        draftSpan: TileSpan(columns: 1, rows: 1),
                                        seededSpan: TileSpan(columns: 1, rows: 1),
                                        storedSpan: TileSpan(columns: 1, rows: 1),
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
                                        storedSpan: TileSpan(columns: 1, rows: 1),
                                        draftMode: .wrap, storedMode: .wrap)
        #expect(edit.modeEdit == nil)
        #expect(edit.hasChanges == false)
    }
}
