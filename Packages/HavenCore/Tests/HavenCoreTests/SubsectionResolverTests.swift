import Testing
@testable import HavenCore

/// `Subsections.resolve` buckets an already-filtered, already-ordered `room.refs(for:)` into the
/// seven subsections. It reimplements none of `refs(for:)`'s own filtering — membership, tiers, and
/// per-room order are exercised there, in `HomeSectionTests` — this only tests the bucketing, the
/// fixed output order, and the mode/span fallback chains.
struct SubsectionResolverTests {
    /// One entity per kind, plus a second light so per-kind ordering has something to prove, plus a
    /// composite whose primary is a cover — bucketed with the shades, exactly as a plain shade is —
    /// plus a composite with no `.primary` entry at all, whose `primaryEntityId` is therefore `nil`
    /// and which `aCompositeWithNoPrimaryIsDroppedFromEveryBucket` asserts lands nowhere.
    /// `overviewOrder` seeds the *overview's own* list, and every test here resolves on
    /// `.overview` — so what they exercise is the surface's own arrangement, never the fallback to
    /// the other surface. That chain is `HomeSectionTests`' subject; conflating the two would let a
    /// resolver that read the wrong surface pass here.
    private func room(overviewOrder: [String] = [], overrides: [String: [HavenSurface: SurfaceMembership]] = [:]) -> RoomSection {
        let refs: [DeviceRef] = [
            .entity("climate.lr"),
            .entity("light.b"),
            .entity("light.a"),
            .entity("cover.blind"),
            .composite(id: "shadegroup", type: "shade_group", inputs: [.primary: ["cover.master"]]),
            .entity("media_player.tv"),
            .entity("camera.front"),
            .entity("scene.evening"),
            .entity("sensor.temp"),
            .composite(id: "orphan", type: "mystery", inputs: [:]),
        ]
        return RoomSection(id: "lounge", name: "Lounge", areaId: "lounge", headerSensors: [],
                           deviceRefs: refs, tiers: [:], overrides: overrides,
                           orders: overviewOrder.isEmpty ? [:] : [.overview: overviewOrder])
    }

    // MARK: - Bucketing and empty-kind dropping

    @Test func emptyKindsAreDropped() {
        let bare = RoomSection(id: "empty", name: "Empty", areaId: "empty", headerSensors: [],
                               deviceRefs: [.entity("light.a")], tiers: [:], overrides: [:], orders: [:])
        let result = Subsections.resolve(room: bare, surface: .overview, document: DashboardDocument())
        #expect(result.map(\.kind) == [.lights])
    }

    /// The approved order is climate, lights, shades, cameras, media, other, sensors — **cameras
    /// before media**, which is not `SubsectionKind.allCases`' declaration order (media, cameras),
    /// matching the schema listing instead. This is the whole point of the fixed constant: a
    /// resolver that used `allCases` would put media first and this test would catch it.
    @Test func outputIsInTheFixedKindOrderWithCamerasBeforeMedia() {
        let result = Subsections.resolve(room: room(), surface: .overview, document: DashboardDocument())
        #expect(result.map(\.kind) == [.climate, .lights, .shades, .cameras, .media, .other, .sensors])
    }

    /// A composite is bucketed by its primary: a shade group whose primary is a cover sits with the
    /// shades, alongside a plain shade — never in its own bucket.
    @Test func aCompositeIsBucketedByItsPrimary() {
        let result = Subsections.resolve(room: room(), surface: .overview, document: DashboardDocument())
        let shades = result.first { $0.kind == .shades }!
        #expect(shades.refs.map(\.id) == ["cover.blind", "shadegroup"])
    }

    /// A composite whose `inputs` has no `.primary` entry has no primary entity id at all
    /// (`DeviceRef.primaryEntityId` is `inputs[.primary]?.first`) — `SubsectionKind.of` cannot take a
    /// value it never receives, so the resolver drops the ref rather than guess a bucket for it.
    /// Mirrors `SubsectionView`'s own handling of the same case (a stored device whose primary
    /// vanished).
    ///
    /// The union of every subsection's refs is the cleanest place to assert "nowhere": checking one
    /// bucket for absence would pass by accident if the ref landed in a *different* one, which is
    /// exactly the failure a wrong implementation (bucketing the orphan into `.other`) produces.
    @Test func aCompositeWithNoPrimaryIsDroppedFromEveryBucket() {
        let result = Subsections.resolve(room: room(), surface: .overview, document: DashboardDocument())
        let everyRef = result.flatMap(\.refs).map(\.id)
        #expect(!everyRef.contains("orphan"))
        // The drop is scoped to the one ref with no primary — its siblings still render.
        #expect(everyRef.contains("light.a"))
    }

    /// Two refs land in the same kind's bucket in the order `refs(for:)` produced them — the
    /// per-room `order` the household arranged, not source or alphabetical order.
    @Test func refsWithinAKindKeepRoomsOrderSequence() {
        let result = Subsections.resolve(room: room(overviewOrder: ["light.a", "light.b"]), surface: .overview,
                                         document: DashboardDocument())
        let lights = result.first { $0.kind == .lights }!
        #expect(lights.refs.map(\.id) == ["light.a", "light.b"])
    }

    // MARK: - Identity

    /// **A subsection's `id` is its kind's raw value, and that is a view's identity.**
    ///
    /// Both surfaces render `ForEach(store.subsections(room, on:))`, so `RoomSubsection.id` is what
    /// SwiftUI uses to decide whether the Lights container on this pass is the *same* Lights
    /// container as on the last one. `resolve` runs afresh on every document or state change, so an
    /// `id` that varied between runs — a UUID, an index, anything derived from the refs — would
    /// give every subsection a new identity several times a second: state discarded, scroll
    /// positions lost, a drag in progress torn out from under the finger.
    ///
    /// Asserted for every case rather than a sample, and through `allCases` rather than a literal
    /// list, so a kind added tomorrow is covered without anybody remembering to add it here.
    @Test func aSubsectionsIdentityIsItsKindsRawValue() {
        for kind in SubsectionKind.allCases {
            let subsection = RoomSubsection(kind: kind, refs: [], span: TileSpan(columns: 1, rows: 1),
                                            mode: .scroll)
            #expect(subsection.id == kind.rawValue)
        }
        // Distinct per kind, which is the half of "identity" the equality above cannot see: an `id`
        // constant across kinds satisfies neither `ForEach` nor this.
        let ids = SubsectionKind.allCases.map {
            RoomSubsection(kind: $0, refs: [], span: TileSpan(columns: 1, rows: 1), mode: .scroll).id
        }
        #expect(Set(ids).count == SubsectionKind.allCases.count)
    }

    // MARK: - Mode fallback chain: subsection override -> household default -> .scroll

    @Test func aSubsectionModeOverrideWinsOverTheHouseholdDefault() {
        let doc = DashboardDocument()
            .settingDisplayMode(.wrap)
            .settingSubsectionMode(.scroll, kind: .lights)
        let result = Subsections.resolve(room: room(), surface: .overview, document: doc)
        #expect(result.first { $0.kind == .lights }!.mode == .scroll)
    }

    @Test func theHouseholdDefaultAppliesWhenNoSubsectionOverride() {
        let doc = DashboardDocument().settingDisplayMode(.wrap)
        let result = Subsections.resolve(room: room(), surface: .overview, document: doc)
        #expect(result.first { $0.kind == .lights }!.mode == .wrap)
    }

    @Test func modeFallsBackToScrollWhenNeitherIsSet() {
        let result = Subsections.resolve(room: room(), surface: .overview, document: DashboardDocument())
        #expect(result.first { $0.kind == .lights }!.mode == .scroll)
    }

    // MARK: - Span fallback chain (decision 10): own surface -> other surface -> kind.defaultSpan(on:)

    /// (a) A surface's own span wins over everything, including the other surface's — mirrors
    /// `HomeSectionTests.aSurfacesOwnOrderWinsOverTheOthers`.
    @Test func aSurfacesOwnSpanWinsOverTheOthers() {
        let doc = DashboardDocument()
            .settingSubsectionSpan(TileSpan(columns: 2, rows: 1), kind: .lights, on: .overview)
            .settingSubsectionSpan(TileSpan(columns: 4, rows: 2), kind: .lights, on: .roomDetail)
        let overview = Subsections.resolve(room: room(), surface: .overview, document: doc)
        let detail = Subsections.resolve(room: room(), surface: .roomDetail, document: doc)
        #expect(overview.first { $0.kind == .lights }!.span == TileSpan(columns: 2, rows: 1))
        #expect(detail.first { $0.kind == .lights }!.span == TileSpan(columns: 4, rows: 2))
    }

    @Test func aSubsectionSpanOverrideWinsOverTheDefault() {
        let doc = DashboardDocument()
            .settingSubsectionSpan(TileSpan(columns: 4, rows: 2), kind: .lights, on: .overview)
        let result = Subsections.resolve(room: room(), surface: .overview, document: doc)
        #expect(result.first { $0.kind == .lights }!.span == TileSpan(columns: 4, rows: 2))
    }

    /// (b) An unset surface follows the other surface's span rather than the kind's default — which
    /// is what makes a camera sized on the floor look sized when room detail is opened, before room
    /// detail has ever been sized for itself. Mirrors
    /// `HomeSectionTests.anUnarrangedSurfaceFollowsTheOtherSurfacesOrder`.
    ///
    /// **Deliberately `2x2` on `.overview`, not `4x2`.** Room detail's own built-in default for a
    /// camera is `4x2` (see `TileSpan.default(for:on:)`) — writing overview to `4x2` and checking
    /// detail resolves to `4x2` would pass even if the fallback chain skipped the other-surface link
    /// entirely and fell straight to detail's own default, which is exactly the bug this test exists
    /// to catch. `2x2` disagrees with detail's default, so the only way this test passes is if the
    /// resolver actually read `.overview`'s stored span.
    @Test func anUnsetSpanFollowsTheOtherSurfacesSpan() {
        let doc = DashboardDocument()
            .settingSubsectionSpan(TileSpan(columns: 2, rows: 2), kind: .cameras, on: .overview)
        let detail = Subsections.resolve(room: room(), surface: .roomDetail, document: doc)
        #expect(detail.first { $0.kind == .cameras }!.span == TileSpan(columns: 2, rows: 2))
    }

    /// (b, the half that discriminates) **It keeps following.** The fallback is resolved fresh on
    /// every call to `resolve`, from whichever document was actually passed in — never cached,
    /// memoised, or otherwise answered from a value some earlier call happened to compute. Two
    /// documents differing *only* in what `.overview` holds, both with `.roomDetail` unset, must
    /// resolve room detail to two different spans. Mirrors
    /// `anUnarrangedSurfaceKeepsFollowingRatherThanSnapshotting`'s discriminating-pair shape: `first`
    /// alone already catches "always fall to my own default" (as in the test above); the pair
    /// together catches "answered from whatever the *previous* call resolved" — a resolver that
    /// remembered `first`'s followed value and reused it regardless of input would pass `first` and
    /// fail `second`.
    @Test func anUnsetSpanKeepsFollowingRatherThanSnapshotting() {
        let first = DashboardDocument()
            .settingSubsectionSpan(TileSpan(columns: 2, rows: 2), kind: .cameras, on: .overview)
        let second = DashboardDocument()
            .settingSubsectionSpan(TileSpan(columns: 4, rows: 2), kind: .cameras, on: .overview)
        let firstDetail = Subsections.resolve(room: room(), surface: .roomDetail, document: first)
        let secondDetail = Subsections.resolve(room: room(), surface: .roomDetail, document: second)
        #expect(firstDetail.first { $0.kind == .cameras }!.span == TileSpan(columns: 2, rows: 2))
        #expect(secondDetail.first { $0.kind == .cameras }!.span == TileSpan(columns: 4, rows: 2))
        #expect(firstDetail.first { $0.kind == .cameras }!.span != secondDetail.first { $0.kind == .cameras }!.span)
    }

    @Test func spanFallsBackToTheKindsDefaultWhenNoOverride() {
        let result = Subsections.resolve(room: room(), surface: .overview, document: DashboardDocument())
        #expect(result.first { $0.kind == .lights }!.span == SubsectionKind.lights.defaultSpan(on: .overview))
    }

    /// (c) Neither surface set: both fall through to `SubsectionKind.defaultSpan(on:)`, which is
    /// where media and cameras disagree with *themselves* across surfaces — the reason `defaultSpan`
    /// takes a surface parameter at all, and the whole point decision 10 exists to preserve. Mirrors
    /// `HomeSectionTests.withNeitherSurfaceArrangedBothTakeTheDefaultOrder`.
    @Test func mediaAndCameraDefaultSpansFollowTheSurface() {
        let overview = Subsections.resolve(room: room(), surface: .overview, document: DashboardDocument())
        let detail = Subsections.resolve(room: room(), surface: .roomDetail, document: DashboardDocument())

        #expect(overview.first { $0.kind == .media }!.span == TileSpan(columns: 2, rows: 1))
        #expect(detail.first { $0.kind == .media }!.span == TileSpan(columns: 4, rows: 2))
        #expect(overview.first { $0.kind == .cameras }!.span == TileSpan(columns: 2, rows: 2))
        #expect(detail.first { $0.kind == .cameras }!.span == TileSpan(columns: 4, rows: 2))
    }

    // MARK: - `resolvedSpan`, standalone

    /// `resolvedSpan` is `resolve`'s per-kind span logic, factored out so `SubsectionConfigView` can
    /// call it directly — it has a kind and a surface but no room to resolve a whole `RoomSubsection`
    /// through. Every case above exercises this same logic *through* `resolve`, on a kind that has
    /// refs; this pins its contract standalone, including for a kind with none at all, which
    /// `resolve` never even asks about (empty kinds are dropped before `resolvedSpan` is called).
    @Test func resolvedSpanAnswersTheFullFallbackChainWithNoRoomAtAll() {
        let doc = DashboardDocument()
            .settingSubsectionSpan(TileSpan(columns: 2, rows: 2), kind: .cameras, on: .overview)
        #expect(Subsections.resolvedSpan(.cameras, on: .overview, document: doc) == TileSpan(columns: 2, rows: 2))
        // Room detail follows overview, exactly as `resolve` does for a kind that has refs.
        #expect(Subsections.resolvedSpan(.cameras, on: .roomDetail, document: doc) == TileSpan(columns: 2, rows: 2))
        // A kind nobody has touched at all, and that this room may not even contain, still gets an
        // answer — the per-surface built-in default.
        #expect(Subsections.resolvedSpan(.lights, on: .overview, document: doc)
                == SubsectionKind.lights.defaultSpan(on: .overview))
    }
}
