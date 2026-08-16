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
    private func room(order: [String] = [], overrides: [String: [HavenSurface: SurfaceMembership]] = [:]) -> RoomSection {
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
                           deviceRefs: refs, tiers: [:], overrides: overrides, order: order)
    }

    // MARK: - Bucketing and empty-kind dropping

    @Test func emptyKindsAreDropped() {
        let bare = RoomSection(id: "empty", name: "Empty", areaId: "empty", headerSensors: [],
                               deviceRefs: [.entity("light.a")], tiers: [:], overrides: [:], order: [])
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
        let result = Subsections.resolve(room: room(order: ["light.a", "light.b"]), surface: .overview,
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

    // MARK: - Span fallback chain: subsection override -> kind.defaultSpan(on:)

    @Test func aSubsectionSpanOverrideWinsOverTheDefault() {
        let doc = DashboardDocument().settingSubsectionSpan(TileSpan(columns: 4, rows: 2), kind: .lights)
        let result = Subsections.resolve(room: room(), surface: .overview, document: doc)
        #expect(result.first { $0.kind == .lights }!.span == TileSpan(columns: 4, rows: 2))
    }

    @Test func spanFallsBackToTheKindsDefaultWhenNoOverride() {
        let result = Subsections.resolve(room: room(), surface: .overview, document: DashboardDocument())
        #expect(result.first { $0.kind == .lights }!.span == SubsectionKind.lights.defaultSpan(on: .overview))
    }

    /// Media and cameras disagree with themselves across surfaces — the reason `defaultSpan` takes a
    /// surface parameter at all. Exercised on both surfaces so a resolver that hard-coded one
    /// surface's default would be caught.
    @Test func mediaAndCameraDefaultSpansFollowTheSurface() {
        let overview = Subsections.resolve(room: room(), surface: .overview, document: DashboardDocument())
        let detail = Subsections.resolve(room: room(), surface: .roomDetail, document: DashboardDocument())

        #expect(overview.first { $0.kind == .media }!.span == TileSpan(columns: 2, rows: 1))
        #expect(detail.first { $0.kind == .media }!.span == TileSpan(columns: 4, rows: 2))
        #expect(overview.first { $0.kind == .cameras }!.span == TileSpan(columns: 2, rows: 2))
        #expect(detail.first { $0.kind == .cameras }!.span == TileSpan(columns: 4, rows: 2))
    }
}
