#if DEBUG
import SwiftUI
import HavenCore

/// Every tile renderer, in the states that have historically been got wrong — on, off, and
/// **unreachable** — on one canvas.
///
/// This exists because the tiles are the one part of the app with no other verification. Nothing in
/// either test suite renders a view, so the sweep that dimmed unreachable tiles
/// (`5e67b60`/`6a3bebc`/`e6ebe54`) was applied by hand, tile by tile, and `SensorTile`'s own comment
/// records that it was missed the first time round — it had no `foregroundStyle` at all. A gallery
/// makes "did every tile get it" a thing you look at once rather than eleven files you re-read.
///
/// `#if DEBUG` so none of this is in a shipping build. Render it with Xcode's canvas, or via the
/// preview tooling, on `App/Renderers/TileGallery.swift`.
///
/// **The 4×2 sizes are here after all, and the reason they once were not has since been checked.**
/// `CameraTile` and `MediaPlayerTile`'s `large` both fetch artwork over the network, and a gallery
/// that renders differently depending on whether a request came back is not a baseline — which is
/// why they were originally excluded. But this file's own `AppModel` has no session, so
/// `AuthenticatedImage` fails its load immediately and every render is the same placeholder; the
/// subsection pages have rendered both at their real cell heights since they arrived (see
/// `subsectionPage(_:_:)`, and `.wideRegular` in particular). That page is now also the regression
/// picture for the two tiles that used to hard-code a height of 141 and so drew shorter than the
/// two rows they occupy — see `CameraTile.wide` and `MediaPlayerTile.large`.
/// Split into pages because a preview snapshot captures one screen, not a scroll view's full
/// content — a single gallery would leave half the tiles unverified below the fold, which is
/// precisely the "assumed rather than looked at" this exists to end. It went from two pages to
/// three when climate grew to eight fixtures at double width and pushed its own `unknown` and
/// `unavailable` cases off the bottom of page one: a page that overflows has quietly stopped being
/// a baseline, so the fix is another page rather than a shorter list.
struct TileGallery: View {
    enum Page {
        case first, second, third, fourth, fifth, sixth, seventh, eighth, ninth, tenth
        /// The subsection container, whose pages are the only thing in the app that renders it — see
        /// `subsectionPage(_:_:)`.
        ///
        /// **Named rather than continuing the ordinals**, deliberately. The ordinals above are
        /// positional: page three is "the one after page two", and which tiles are on it is a
        /// history of what overflowed. These six are one construct rendered along two axes, so they
        /// are named for the axes — a set, not a sequence.
        case narrowCompact, narrowRegular, wideCompact, wideRegular, sensors, configuring
        /// The same container at a 4×1, one page per kind that offers one. Named for the kind rather
        /// than for the axes — as `sensors` above already is, and for the same reason: each exists
        /// for a span no *default* reaches, so it is a size a household must choose before anything
        /// in this file draws it.
        case mediaRows, climateRows
    }
    let page: Page

    /// One store, pre-loaded with a fixture per case below. The tiles read `@Environment`, so this
    /// is the only way to drive them.
    @State private var store = TileGallery.populatedStore()
    /// The tiles write their long-press target into this. Nothing here presents a modal, but the
    /// environment has to hold one or every tile traps on a missing value.
    ///
    /// **Seeded from `page` at `init`, not flipped in `.onAppear`** — the in-repo model is
    /// `SubsectionDragPreviewHost`. A flag flipped on appearance renders one frame of the
    /// unconfigured body before the update lands, which for the `.configuring` page is a frame of
    /// scroll mode with none of the placeholders it exists to show. Seeding it here also drops the
    /// old cross-page contamination risk outright rather than guarding against it: each
    /// `TileGallery(page:)` value now builds its own `Navigation`, so there is no shared instance
    /// left for one page's setting to leak into another's.
    @State private var navigation: Navigation
    /// `AuthenticatedImage` reads it for the base URL, which `CameraTile` needs to exist at all.
    /// **No connection is made** — no request is ever sent, so the cameras page renders the same
    /// placeholder every time rather than depending on what a server happened to return — but the
    /// value is not otherwise inert: `AppModel.init` runs a real `UserDefaults` migration
    /// (`DiscoveredURLMigration`) against the default `.standard` domain on construction.
    @State private var app = AppModel()

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    init(page: Page) {
        self.page = page
        let navigation = Navigation()
        navigation.isConfiguring = page == .configuring
        _navigation = State(initialValue: navigation)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch page {
                case .first:
                    // "unlabelled" is item 2's fixture (tile-refinements): a light with its name
                    // hidden, beside three labelled siblings — the state a "Show name on tile"
                    // toggle produces, visible in the same row it sits in. Its own id rather than
                    // reusing `light.off`: `light.off` is also in `twoStateCases` below, which page
                    // `.sixth` renders twice (once per state style) on the stated premise that both
                    // rows show "the same devices, same states" — hiding its label there would make
                    // the icon-style tile and its `_l` twin disagree on more than the one thing that
                    // page exists to compare.
                    section("Light") { ids("light", ["on", "off", "unlabelled", "unavailable"]) }
                    section("Switch") { ids("switch", ["on", "off", "unavailable"]) }
                    section("Cover") { ids("cover", ["open", "closed", "unavailable"]) }
                    // Four, not three: `unavailable` must render `questionmark.circle` and **not**
                    // either padlock glyph — the one place in the tiles where the *symbol*, not
                    // just its colour, is a state claim. See `LockTile`.
                    section("Lock") { ids("lock", ["locked", "unlocked", "jammed", "unavailable"]) }
                    // Four, and the first two are the point: `heat`-and-heating is filled,
                    // `heat`-and-idle is not, and they are otherwise the same tile. The fill now
                    // tracks `hvac_action` rather than on/off (see `ClimateState.isConditioning`),
                    // which is a distinction you can only check by looking at the two side by side.
                    // The unavailable case is the most prominent state claim on any tile: a
                    // thermostat's target temperature is read straight from a cached attribute, so
                    // an unreachable one has a number to show whether or not it means anything.
                    // `unknown` is the fifth for the same reason the lock row has four: it is dimmed
                    // and struck like `unavailable`, but its power button is *live*, because an
                    // unknown thermostat is reachable and a tap is what resolves it. Two tiles that
                    // look alike and behave differently is precisely a thing to look at rather than
                    // infer.
                case .second:
                    section("Scene") { ids("scene", ["idle", "unavailable"]) }
                    // The tile the original sweep actually missed.
                    section("Sensor") { ids("sensor", ["value", "unavailable"]) }
                    section("Binary sensor") { ids("binary_sensor", ["active", "clear", "unavailable"]) }
                    section("Generic") { ids("generic", ["idle", "unavailable"]) }
                    sensorWide
                    // Media used to be here too — a 1×1 row through `ids(...)` and `mediaWide`
                    // below it. The 1×1 rendering was withdrawn (tile refinements, item 3), which
                    // also disqualified `ids(...)` for media outright: it lays out in a 4-column
                    // grid, and media's overview default is now 2×1, so every tile in that row
                    // would have been a two-column rendering drawn one column wide. Both sizes
                    // moved to page `.ninth` when the new 4×1 needed room — see `mediaRow`.
                case .fourth:
                    section("Room configuration — candidates, and none") {
                        VStack(alignment: .leading, spacing: 16) {
                            RoomConfigView(areaId: "lounge")
                            Divider()
                            RoomConfigView(areaId: "hall")
                        }
                    }
                case .fifth:
                    section("Add a device") {
                        VStack(alignment: .leading, spacing: 14) {
                            LazyVGrid(columns: Self.columns, spacing: 10) {
                                DeviceTileView(entityId: "light.on", surface: .overview)
                                AddTilePlaceholder { }
                            }
                            Divider()
                            AddTileView(areaId: "lounge", surface: .overview)
                            Divider()
                            // **The second step**, which is otherwise only reachable by tapping a
                            // cover — and an unrendered state is one nobody has looked at.
                            AddTileView(areaId: "lounge", surface: .overview,
                                        choosingTypeForPreview: "cover.open")
                        }
                    }
                    // The two configuration sheets have no other verification, which is the same
                    // argument this file makes about the tiles. Rendered side by side rather than
                    // only next to their own views, so the pair is reviewed as a pair.
                case .sixth:
                    stateStyles
                case .seventh:
                    climateLarge
                case .eighth:
                    deviceContext
                case .ninth:
                    mediaWide
                    mediaRow
                case .tenth:
                    climateRow4x1
                case .narrowCompact: subsectionPage(Self.narrowKinds, .compact)
                case .narrowRegular: subsectionPage(Self.narrowKinds, .regular)
                case .wideCompact: subsectionPage(Self.wideKinds, .compact)
                case .wideRegular: subsectionPage(Self.wideKinds, .regular)
                case .sensors: sensorSubsections
                case .mediaRows: mediaRowSubsections
                case .climateRows: climateRowSubsections
                case .configuring: configuringSubsections
                case .third:
                    // **Two columns, because that is the only width this tile is ever drawn at.**
                    // The Climate subsection is two columns wide on both surfaces
                    // (`SubsectionKind.climate.defaultSpan(on:)`), so rendering it here through the
                    // 4-column `ids(...)` was the gallery lying about the one thing it exists to
                    // show. It cost something real: judgements about what fits beside the target
                    // temperature were made against half the width the tile actually has.
                    section("Climate") { climateRow }
                }
            }
            .padding()
        }
        .environment(store)
        .environment(navigation)
        .environment(app)
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func ids(_ domain: String, _ cases: [String]) -> some View {
        LazyVGrid(columns: Self.columns, spacing: 10) {
            ForEach(cases, id: \.self) { name in
                DeviceTileView(entityId: "\(domain).\(name)", surface: .overview)
            }
        }
    }

    /// **The two ways a two-state tile can show itself**, side by side, because the choice between
    /// them is a household setting and neither is obviously right. The glyphs differ between states
    /// — an open door against a closed one, a filled power symbol against a hollow one — which is
    /// what makes the icon style worth having; the label style exists for the device classes where a
    /// picture is a guess.
    ///
    /// The unreachable cases are here deliberately. Both styles must say "Unavailable" rather than
    /// asserting a state, and the lock is the one where getting that wrong is a security claim.
    private var stateStyles: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Icon — light, binary sensor, lock, cover, switch") {
                LazyVGrid(columns: Self.columns, spacing: 10) {
                    ForEach(Self.twoStateCases, id: \.self) { id in
                        DeviceTileView(entityId: id, surface: .overview)
                    }
                }
            }
            section("Label — the same devices, same states") {
                LazyVGrid(columns: Self.columns, spacing: 10) {
                    ForEach(Self.twoStateCases.map { $0 + "_l" }, id: \.self) { id in
                        DeviceTileView(entityId: id, surface: .overview)
                    }
                }
            }
        }
    }

    /// **Typed and hoisted out of the view builder deliberately.** As inline literals inside
    /// `ForEach` these two lists compiled fine in a normal build and defeated the *preview*
    /// compiler — "unable to type-check this expression in reasonable time" — which would have made
    /// the one page that verifies this feature the one page nobody could look at.
    ///
    /// The label row is these same ids with a suffix, so the two rows cannot drift apart: a case
    /// added to one is added to both.
    /// The three derived-state garages. **A named type rather than an array of tuples**, because as
    /// a literal inside the fixture builder this defeated the *preview* compiler — "unable to
    /// type-check this expression in reasonable time" — while compiling fine in a normal build. The
    /// same trap `twoStateCases` records below.
    struct GarageFixture { let id: String; let name: String; let closed: String; let open: String }
    private static let garages: [GarageFixture] = [
        GarageFixture(id: "cover.limit_closed", name: "Garage A", closed: "on", open: "off"),
        GarageFixture(id: "cover.partly", name: "Garage B", closed: "off", open: "off"),
        GarageFixture(id: "cover.limit_open", name: "Garage C", closed: "off", open: "on"),
    ]

    /// The "Every Kind" room's devices, in the order the room holds them.
    ///
    /// **Hoisted and typed**, for the reason `twoStateCases` records below: as a literal inside the
    /// fixture builder a list this long compiles fine in a normal build and defeats the *preview*
    /// compiler, which would make the pages this exists for the ones nobody can look at.
    private static let subsectionEntityIds: [String] = [
        "climate.sub_a", "climate.sub_b",
        "light.sub_0", "light.sub_1", "light.sub_2", "light.sub_3", "light.sub_4",
        "cover.sub_a", "cover.sub_b", "cover.sub_c",
        "media_player.sub_a", "media_player.sub_b",
        "camera.sub_a", "camera.sub_b",
        "scene.sub_a", "lock.sub_a", "switch.sub_a",
        "sensor.sub_power", "binary_sensor.sub_door",
        "sensor.sub_energy", "binary_sensor.sub_motion",
    ]

    /// `supported_features` for a speaker that can do everything the transport draws:
    /// `pause | volumeSet | volumeMute | previousTrack | nextTrack | play`.
    ///
    /// Written as the union of `MediaPlayerFeatures`' own values rather than as `16445`, so the
    /// fixture says which controls it is asking for and a reader does not have to decompose a
    /// number to find out.
    private static let prevNextPlayPause: Int = MediaPlayerFeatures([
        .pause, .volumeSet, .volumeMute, .previousTrack, .nextTrack, .play,
    ]).rawValue

    private static let twoStateCases: [String] = [
        "light.on", "light.off",
        "binary_sensor.active", "binary_sensor.clear",
        "lock.locked", "lock.unlocked", "lock.jammed",
        "cover.open", "cover.closed",
        "switch.on", "switch.off",
        "binary_sensor.unavailable", "lock.unavailable", "switch.unavailable",
        "cover.unavailable", "light.unavailable",
    ]

    /// **What else a device knows**, in the three shapes that decide whether the card is honest.
    ///
    /// The no-companion case is the important one: it must draw *nothing at all*, because every
    /// device in a home without a registry `device_id` is that case and none of them should grow an
    /// empty card. The unreachable reading is the second: an offline sensor and an absent one must
    /// not look the same.
    private var deviceContext: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("No companions, nothing derived — both cards draw nothing") {
                VStack(spacing: 10) {
                    DeviceStateCard(entityId: "light.on")
                    DeviceContextCard(entityId: "light.on")
                }
            }
            // What the peek modal now shows for a composite: the state Haven works out, and the
            // sensors it came from.
            section("Computed state, and what it came from") {
                VStack(spacing: 10) {
                    DeviceStateCard(entityId: "switch.opener")
                    DeviceStateCard(entityId: "cover.partly")
                    DeviceStateCard(entityId: "cover.open_only")
                }
            }
            section("A lock, and whether the door is actually shut") {
                DeviceContextCard(entityId: "lock.locked")
            }
            section("Several, including one unreachable") {
                DeviceContextCard(entityId: "cover.open")
            }
            // **The state a cover entity has no word for.** `cover.partly` reports "open" like any
            // other; its two bound limit sensors both reading off is the only way to know the door
            // is stopped half way.
            section("Derived from bound limits — including one sensor only") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 2),
                          spacing: 9) {
                    ForEach(["cover.limit_closed", "cover.partly", "cover.limit_open",
                             "switch.opener", "cover.open_only",
                             "cover.closed_only"], id: \.self) { id in
                        DeviceTileView(entityId: id, surface: .overview)
                    }
                }
            }
        }
    }

    /// **The 4×2 climate tile, at the height a room actually gives it.**
    ///
    /// 173pt — two `RoomGrid` rows plus the spacing between them — rather than whatever a `VStack`
    /// would hand it. That distinction is the entire reason this section exists: a tile that looks
    /// right at its natural height and overflows at its real one is a tile nobody has verified.
    private var climateLarge: some View {
        section("Climate — 4×2, at a room's row height") {
            VStack(spacing: 10) {
                ForEach(["climate.heating", "climate.off", "climate.unavailable"], id: \.self) { id in
                    ClimateTile(entityId: id, size: .large)
                        .frame(height: 173)
                }
            }
        }
    }

    /// **The 4×1, in the five states that draw it differently.** Full width, which is what this size
    /// is: one line of icon, the room's temperature with the mode-and-fan word beside it, and the
    /// setpoint between its own two buttons on the right.
    ///
    /// The five are chosen for what each one changes. `heating` and `idle` are the fill pair — same
    /// mode, same target, one washed and one not — which is the only way to see that the wash tracks
    /// `hvac_action` and not on/off; `cooling` is the other accent beside them. `off` is the biggest
    /// layout change this size makes: `setpointControl` is absent entirely, so the row is a readout
    /// and a power button with a long gap between them, and whether that gap reads as deliberate or
    /// as a tile that failed to fill itself is a question for eyes. `unavailable` must be struck and
    /// assert nothing — note it has a cached `temperature` and shows it nowhere, because an
    /// unreachable thermostat is never `isOn` and so never draws a setpoint at all.
    ///
    /// **Every fixture here declares two `hvac_modes`, and this size draws none of them.** That is
    /// not an omission in the fixtures — see `ClimateTile.row`, which cut the mode row because seven
    /// declared modes will not share a line with a stepper cluster. It is recorded here because this
    /// page is where somebody would otherwise go looking for them.
    ///
    /// **Not** rendered at a stated height, unlike `climateLarge` directly above it: a 4×1 is a
    /// single-row span, and single-row is the case both hosts size by *measuring* the tile rather
    /// than proposing to it (`RoomGrid.rowHeight`, `SubsectionView.tileHeight`). Its own ideal height
    /// is therefore the honest thing to look at, and stating a number would be this gallery
    /// asserting the very thing the tile is supposed to be asked. Worth reading against `mediaRow`
    /// on page `.ninth`: they are the app's only two 4×1 renderings, and a room holding both gets
    /// one row height for the pair.
    private var climateRow4x1: some View {
        section("Climate — 4×1") {
            VStack(spacing: 10) {
                ForEach(["heating", "cooling", "idle", "off", "unavailable"], id: \.self) { name in
                    ClimateTile(entityId: "climate.\(name)", size: .row)
                }
            }
        }
    }

    /// Climate at its default width: 2 of 4 columns, as both surfaces draw it unless a household
    /// says otherwise.
    private var climateRow: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 2), spacing: 9) {
            ForEach(["heating", "cooling", "drying", "fan", "idle", "off", "unknown", "unavailable"], id: \.self) { name in
                DeviceTileView(entityId: "climate.\(name)", surface: .overview)
            }
        }
    }

    /// The 2×1 sensor, in the three states that decide whether it draws a line at all.
    ///
    /// **The empty and flat cases are the point.** A sparkline with nothing behind it must render as
    /// a plain reading rather than as an axis-less chart of one point, and that is invisible in the
    /// happy case — which is exactly the kind of thing this gallery exists to make visible.
    private var sensorWide: some View {
        section("Sensor — 2×1") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 2), spacing: 9) {
                SensorTile(entityId: "sensor.value", size: .wide)
                SensorTile(entityId: "sensor.spiky", size: .wide)
                SensorTile(entityId: "sensor.nohistory", size: .wide)
                SensorTile(entityId: "sensor.text", size: .wide)
            }
        }
    }

    /// The 2×1 size, which took its own commit to get struck (`e6ebe54`) — so it is worth looking
    /// at rather than assumed to match its siblings.
    ///
    /// **Two of four columns, because that is the width this size is ever drawn at.** It was a
    /// full-width `VStack` until the 4×1 arrived and made the difference matter: with a genuinely
    /// full-width media tile on the same page, a 2×1 drawn full width would have made the two look
    /// like the same size. That is the identical correction page `.third` records making for
    /// climate, for the identical reason.
    ///
    /// `nolabel` is the hidden-label case, and it is the one to *judge* rather than check: a player
    /// with its name hidden and nothing playing has no text for the title window, so the window
    /// renders blank beside a live transport. Whether that reads as a tile with nothing to say or as
    /// a tile that failed is a question for eyes, and the answer decides whether the slot wants a
    /// placeholder glyph. The 4×1 below renders the same fixture for the same question.
    private var mediaWide: some View {
        section("Media player — 2×1") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 2), spacing: 9) {
                MediaPlayerTile(entityId: "media_player.playing", size: .wide)
                MediaPlayerTile(entityId: "media_player.full", size: .wide)
                MediaPlayerTile(entityId: "media_player.nolabel", size: .wide)
                MediaPlayerTile(entityId: "media_player.unavailable", size: .wide)
            }
        }
    }

    /// **The 4×1, in the five states that draw differently.** Full width, which is what this size
    /// is: one line of icon, scrolling title and the whole transport.
    ///
    /// The five are chosen for what each one changes. `full` is playing with a title and every
    /// transport bit set — the complete cluster, and the scrolling window with something long
    /// enough in it to actually travel. `paused` is the same tile with the glyph flipped and the
    /// tile's lit background gone, which is the pair the `isPlaying` tint is about. `idle` declares
    /// no features at all: no title, no prev/next, and `playPauseButton`'s dead-placeholder branch
    /// where the button would be — the omit-don't-disable rule, which is invisible unless a fixture
    /// has nothing to offer. `unavailable` must be struck and assert nothing. `nolabel` is the
    /// hidden-label case described on `mediaWide` above.
    ///
    /// **Not** rendered at a stated height, unlike `climateLarge`: a 4×1 is a single-row span, and
    /// single-row is the case both hosts size by *measuring* the tile rather than proposing to it
    /// (`RoomGrid.rowHeight`, `SubsectionView.tileHeight`). Its own ideal height is therefore the
    /// honest one to look at here, and stating a number would be this gallery asserting the very
    /// thing the tile is supposed to be asked.
    private var mediaRow: some View {
        section("Media player — 4×1") {
            VStack(spacing: 10) {
                ForEach(["full", "paused", "idle", "unavailable", "nolabel"], id: \.self) { name in
                    MediaPlayerTile(entityId: "media_player.\(name)", size: .row)
                }
            }
        }
    }

    // MARK: - Subsections

    /// Split by how wide the kind's tiles are rather than by anything about the kinds themselves:
    /// three 1×1 kinds fit one page in both modes, and the kinds that take two or four columns do
    /// not. A page that overflows has quietly stopped being a baseline — the same argument that gave
    /// climate a page of its own.
    private static let narrowKinds: [SubsectionKind] = [.lights, .shades, .other]
    private static let wideKinds: [SubsectionKind] = [.climate, .media, .cameras]

    /// The room every subsection fixture is bucketed out of — the "Every Kind" area in
    /// `populatedStore`.
    private var subsectionsRoom: RoomSection? {
        store.rooms().first { $0.areaId == "subs" }
    }

    /// Which surface a density is paired with.
    ///
    /// **The gallery's pairing, not a rule inside the view.** `SubsectionView` takes the two
    /// separately and on purpose — see its `surface` doc comment — but the floor is always compact
    /// and room detail always regular, so a fixture states one and gets the other.
    ///
    /// It follows that the regular-density pages resolve on `.roomDetail`, where media and cameras
    /// default to the full four columns. A media player twice the size of the one on the compact
    /// page is that default, not a bug: room detail is a room you are in, and `TileSpan.default`
    /// has always said so.
    private static func surface(for density: SubsectionDensity) -> HavenSurface {
        density == .compact ? .overview : .roomDetail
    }

    /// Each kind at one density, in both modes, one directly above the other.
    ///
    /// **Adjacent deliberately, and the two axes of the comparison are not equally guaranteed.**
    /// *Widths* cannot disagree between the modes — both ask one `RoomGrid` value how wide a span is
    /// — so a width that differs means the scroll body's measured container width is wrong. *Heights*
    /// are only guaranteed for multi-row spans; a single-row scroll tile takes its own ideal height
    /// because an `HStack` has no subviews to measure, and it matches its wrap twin only because a
    /// subsection's tiles are the same renderer at the same span. See `SubsectionView.tileHeight`.
    /// A single-row height that differs is therefore a height-mechanics finding, not a width one.
    private func subsectionPage(_ kinds: [SubsectionKind], _ density: SubsectionDensity) -> some View {
        ForEach(kinds, id: \.self) { kind in
            subsectionCase(kind, .scroll, density)
            subsectionCase(kind, .wrap, density)
        }
    }

    @ViewBuilder
    private func subsectionCase(_ kind: SubsectionKind, _ mode: SubsectionMode,
                                _ density: SubsectionDensity, span: TileSpan? = nil) -> some View {
        let surface = Self.surface(for: density)
        if let room = subsectionsRoom,
           let resolved = subsectionFixture(kind, mode: mode, surface: surface, span: span, room: room) {
            section(subsectionLabel(kind, mode, density, span)) {
                SubsectionView(room: room, subsection: resolved, surface: surface, density: density)
            }
        } else {
            // **A page that quietly renders nothing on a broken fixture is the bug this file exists
            // to catch** — see the type's own doc comment on "the sweep that dimmed unreachable
            // tiles was applied by hand". Every kind this gallery drives (`Self
            // .subsectionEntityIds`) sits in the "Every Kind" room at `.primary` tier on both
            // surfaces, so nothing here is an expected empty state — a nil is always the room
            // fixture missing or `Subsections.resolve` no longer producing this kind, and it should
            // read as a defect on the canvas rather than a gap nobody notices.
            section(subsectionLabel(kind, mode, density, span)) {
                Text("Unresolved — no fixture for this case")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HavenColor.warning)
            }
        }
    }

    /// One fixture subsection, resolved through the real chain.
    ///
    /// **`RoomSubsection` has no public initializer, deliberately** — so a fixture here is a room
    /// and a document rather than a hand-built value. That is the better fixture anyway: the
    /// bucketing, the mode fallback and the span fallback all run on the way past, exactly as they
    /// do in the app, so a page cannot show a state the resolver would never produce.
    private func subsectionFixture(_ kind: SubsectionKind, mode: SubsectionMode,
                                   surface: HavenSurface, span: TileSpan?,
                                   room: RoomSection) -> RoomSubsection? {
        var document = store.config.document.settingSubsectionMode(mode, kind: kind)
        // `on: surface` — decision 10 made span per-surface, and this fixture already knows which
        // surface it is building a page for.
        if let span { document = document.settingSubsectionSpan(span, kind: kind, on: surface) }
        return Subsections.resolve(room: room, surface: surface, document: document)
            .first { $0.kind == kind }
    }

    private func subsectionLabel(_ kind: SubsectionKind, _ mode: SubsectionMode,
                                 _ density: SubsectionDensity, _ span: TileSpan?) -> String {
        let densityName = density == .compact ? "compact (floor)" : "regular (room detail)"
        return "\(kind.displayName) — \(densityName) · \(mode.rawValue)"
            + (span.map { " · \($0.stored)" } ?? "")
    }

    /// **The open question this task exists to put in front of a person.**
    ///
    /// A Sensors subsection can be configured 2×1 — a sparkline size, offered because
    /// `SubsectionKind.sensors.availableSpans` follows the kind's *most capable* member — while a
    /// `binary_sensor` in it has no 2×1 rendering at all and falls back to its 1×1 content inside a
    /// 2×1 cell (see `DeviceTileView.tile`). Whether that reads as a deliberate size or as a tile
    /// that failed to fill its box is a judgement, not something a test can settle. The 1×1 default
    /// is directly above it so the two can be compared rather than described.
    @ViewBuilder
    private var sensorSubsections: some View {
        ForEach([SubsectionDensity.compact, .regular], id: \.self) { density in
            subsectionCase(.sensors, .scroll, density)
            subsectionCase(.sensors, .wrap, density)
            subsectionCase(.sensors, .scroll, density, span: TileSpan(columns: 2, rows: 1))
            subsectionCase(.sensors, .wrap, density, span: TileSpan(columns: 2, rows: 1))
        }
    }

    /// **The 4×1 inside the container that measures it** — the thing page `.ninth` cannot show, since
    /// those are bare tiles in a `VStack` and the claim worth checking is what a `RoomGrid` does when
    /// it asks this tile how tall it is.
    ///
    /// A Media subsection is only ever 4×1 because a household picked it — the defaults are 2×1 and
    /// 4×2 — so this is a `span:` override, for exactly the reason `sensorSubsections` overrides to
    /// 2×1: a size on offer that no default reaches is a size nobody has looked at.
    ///
    /// **Both modes, because single-row is precisely the case `subsectionPage(_:_:)`'s doc comment
    /// says is not guaranteed to agree.** Wrap takes the tallest single-row tile's *measured* ideal
    /// and hands it to every row; scroll gives each tile the ideal it asks for. They match only
    /// because a subsection's tiles are the same renderer at the same span — so if these two sections
    /// ever differ in height, that is the guarantee breaking rather than a width problem, and
    /// `MediaPlayerTile.row`'s "it takes its own height" note is where to start.
    ///
    /// Its own page rather than another section on `.wideCompact` or a third on `.ninth`: both are
    /// full, and this file's standing rule is that a page which overflows has stopped being a
    /// baseline. Named for its kind rather than for the two axes, as `.sensors` already is, because
    /// like that one it exists for a non-default span rather than for a density/mode pairing.
    @ViewBuilder
    private var mediaRowSubsections: some View {
        subsectionCase(.media, .scroll, .compact, span: TileSpan(columns: 4, rows: 1))
        subsectionCase(.media, .wrap, .compact, span: TileSpan(columns: 4, rows: 1))
    }

    /// **The other 4×1, inside the container that measures it** — everything `mediaRowSubsections`
    /// above says, said about climate. Page `.tenth` renders these tiles bare in a `VStack`; the
    /// claim worth checking is what a `RoomGrid` does when it asks one how tall it is.
    ///
    /// A Climate subsection is 4×1 only because a household picked it — the default is 2×1 on both
    /// surfaces — so this is a `span:` override, for the reason `sensorSubsections` established: a
    /// size on offer that no default reaches is a size nobody has looked at.
    ///
    /// **Both modes**, because single-row is exactly the case `subsectionPage(_:_:)`'s doc comment
    /// says is *not* guaranteed to agree: wrap hands every row the tallest measured single-row ideal,
    /// scroll gives each tile the ideal it asks for. A height difference between these two sections
    /// is that guarantee breaking, and `ClimateTile.row`'s "it takes its own height" note is where to
    /// start. The pair is the check; either alone is not.
    ///
    /// **Its own page rather than two more sections on `.mediaRows`.** Two kinds × two modes × two
    /// full-width tiles is past a screen, and this file's standing rule is that a page which
    /// overflows has stopped being a baseline.
    ///
    /// `climate.sub_b` is the off thermostat, which is the case to look at here: with no setpoint
    /// drawn, its line is the shortest this size produces, and it still has to measure the same
    /// height as `sub_a` above it or a Climate subsection has rows of two sizes.
    @ViewBuilder
    private var climateRowSubsections: some View {
        subsectionCase(.climate, .scroll, .compact, span: TileSpan(columns: 4, rows: 1))
        subsectionCase(.climate, .wrap, .compact, span: TileSpan(columns: 4, rows: 1))
    }

    /// **Configuration mode, where every subsection wraps** whatever the household configured —
    /// design decision 8, because rearranging happens on a grid and never inside a scroll row.
    ///
    /// The first three are configured `.scroll` and not one of them renders as one; that flip is
    /// the thing to look at. Their headings are tap targets rather than labels, which is the other
    /// — and it is deliberately undecorated, exactly as a room's heading is in the same mode.
    ///
    /// **The fourth, `.media`/`.regular`, is a regression fixture for the blank-row defect a
    /// hands-on pass found**: two media players at room detail's full-bleed 4×2 default fill exactly
    /// two whole rows with nothing left over, which is precisely the condition
    /// `SubsectionView.endDropCell`'s doc comment now names — a subsection whose last real row is
    /// exactly full pushes the end-drop cell (1 column, `span.rows` tall) to a *new* row of its own,
    /// and an idle configuration screen paid for that row's height with nothing in it. Confirmed by
    /// hand against `GridPacking.place` before this fixture was written: two 4×2 spans plus a 1×2
    /// end cell in a 4-column grid come back with `rowCount == 6` while only the first four rows
    /// hold a real tile.
    ///
    /// **Not the only fixture on this page that could have shown it, in hindsight.** `.lights` (5
    /// tiles in 4 columns) and `.shades` (3 tiles in 4 columns) both leave a genuinely partial last
    /// row, which is where the defect actually hid — the end cell tucks in beside real tiles rather
    /// than forcing a new one. `.cameras`, though, is two 2×2 tiles at the compact/overview default,
    /// which also fills exactly four columns and — checked the same way, `GridPacking.place` on
    /// `[2×2, 2×2, 1×2]` at 4 columns — comes back `rowCount == 4` against two rows of real content.
    /// It was already reproducing this defect before this fixture was added; it went unnoticed on
    /// this page regardless, which is itself worth naming rather than only adding a new case beside
    /// it. This fixture is deliberately the loudest version, at the exact width and site (room
    /// detail, a full-bleed tile) the hands-on report described.
    @ViewBuilder
    private var configuringSubsections: some View {
        subsectionCase(.lights, .scroll, .compact)
        subsectionCase(.cameras, .scroll, .compact)
        subsectionCase(.shades, .scroll, .regular)
        subsectionCase(.media, .scroll, .regular)
    }

    // MARK: - Fixtures

    @MainActor
    private static func populatedStore() -> HomeStore {
        let store = HomeStore()
        func set(_ id: String, _ state: String, _ attributes: [String: JSONValue] = [:]) {
            store.states[id] = EntityState(entityId: id, state: state, attributes: attributes,
                                           lastUpdated: Date(timeIntervalSince1970: 0))
        }
        set("light.on", "on", ["friendly_name": .string("Kitchen"), "brightness": .int(153)])
        set("light.off", "off", ["friendly_name": .string("Hallway")])
        // Item 2 (tile-refinements): its label is hidden below, alongside `document`'s other
        // household choices — see that comment for why this is its own fixture rather than a
        // `light.off` shared with `twoStateCases`.
        set("light.unlabelled", "off", ["friendly_name": .string("Landing")])
        set("light.unavailable", "unavailable", ["friendly_name": .string("Porch")])

        set("switch.on", "on", ["friendly_name": .string("Fan")])
        set("switch.off", "off", ["friendly_name": .string("Heater")])
        set("switch.unavailable", "unavailable", ["friendly_name": .string("Pump")])

        set("cover.open", "open", ["friendly_name": .string("Blinds"), "current_position": .int(70)])
        set("cover.closed", "closed", ["friendly_name": .string("Garage"), "current_position": .int(0)])
        set("cover.unavailable", "unavailable", ["friendly_name": .string("Awning")])

        set("lock.locked", "locked", ["friendly_name": .string("Front")])
        set("lock.unlocked", "unlocked", ["friendly_name": .string("Back")])
        set("lock.jammed", "jammed", ["friendly_name": .string("Side")])
        set("lock.unavailable", "unavailable", ["friendly_name": .string("Shed")])

        // One fixture per `hvac_action` the tile colours, plus the three states that have no
        // action to colour by. Same mode and target where they can be, so the only difference on
        // screen is the one being checked.
        set("climate.heating", "heat", ["friendly_name": .string("Lounge"), "temperature": .double(21),
            "current_temperature": .double(20.4),
                                        "fan_mode": .string("auto"), "hvac_action": .string("heating"),
                                        "hvac_modes": .array([.string("off"), .string("heat")])])
        set("climate.cooling", "cool", ["friendly_name": .string("Study"), "temperature": .double(19),
            "current_temperature": .double(22.1),
                                        "fan_mode": .string("auto"), "hvac_action": .string("cooling"),
                                        "hvac_modes": .array([.string("off"), .string("cool")])])
        set("climate.drying", "dry", ["friendly_name": .string("Cellar"), "temperature": .double(20),
            "current_temperature": .double(19.6),
                                      "hvac_action": .string("drying"),
                                      "hvac_modes": .array([.string("off"), .string("dry")])])
        set("climate.fan", "fan_only", ["friendly_name": .string("Porch"), "temperature": .double(22),
            "current_temperature": .double(20.8),
                                        "fan_mode": .string("high"), "hvac_action": .string("fan"),
                                        "hvac_modes": .array([.string("off"), .string("fan_only")])])
        // On and at target: the pair with `climate.heating` that the fill rule is about.
        set("climate.idle", "heat", ["friendly_name": .string("Hall"), "temperature": .double(21),
            "current_temperature": .double(20.4),
                                     "fan_mode": .string("auto"), "hvac_action": .string("idle"),
                                     "hvac_modes": .array([.string("off"), .string("heat")])])
        set("climate.off", "off", ["friendly_name": .string("Attic"), "temperature": .double(18),
            "current_temperature": .double(20.8),
                                   "hvac_modes": .array([.string("off"), .string("heat")])])
        set("climate.unknown", "unknown", ["friendly_name": .string("Garage"), "temperature": .double(19),
            "current_temperature": .double(22.1),
                                           "hvac_modes": .array([.string("off"), .string("heat")])])
        set("climate.unavailable", "unavailable", ["friendly_name": .string("Loft"),
                                                   "temperature": .double(23)])

        // For the configuration page: two temperature sources called almost the same thing, which
        // is what the entity id on every picker row is for, plus a room with nothing to pick.
        set("sensor.lounge_temp", "21.5", ["friendly_name": .string("Lounge Temperature"),
                                           "device_class": .string("temperature"),
                                           "unit_of_measurement": .string("°C")])
        set("sensor.lounge_temp_window", "20.9", ["friendly_name": .string("Temperature"),
                                                  "device_class": .string("temperature"),
                                                  "unit_of_measurement": .string("%")])
        set("sensor.lounge_hum", "44", ["friendly_name": .string("Lounge Humidity"),
                                        "device_class": .string("humidity"),
                                        "unit_of_measurement": .string("%")])
        set("sensor.lounge_hum_2", "46", ["friendly_name": .string("Lounge Humidity (window)"),
                                          "device_class": .string("humidity"),
                                          "unit_of_measurement": .string("%")])

        set("scene.idle", "scening", ["friendly_name": .string("Movie")])
        set("scene.unavailable", "unavailable", ["friendly_name": .string("Away")])

        set("sensor.spiky", "63", ["friendly_name": .string("Power"),
                                   "device_class": .string("power"),
                                   "unit_of_measurement": .string("W")])
        set("sensor.nohistory", "18.2", ["friendly_name": .string("Shed"),
                                         "device_class": .string("temperature"),
                                         "unit_of_measurement": .string("°C")])
        // A sensor whose state is a word. It is offered the 2×1 like every other sensor — the option
        // set is a fact about the device type, not about today's reading — and it simply has no line.
        set("sensor.text", "Away", ["friendly_name": .string("Mode")])
        set("sensor.value", "21.4", ["friendly_name": .string("Temp"),
                                     "device_class": .string("temperature"),
                                     "unit_of_measurement": .string("°C")])
        set("sensor.unavailable", "unavailable", ["friendly_name": .string("Humidity"),
                                                  "device_class": .string("humidity")])

        set("binary_sensor.active", "on", ["friendly_name": .string("Door"),
                                           "device_class": .string("door")])
        set("binary_sensor.clear", "off", ["friendly_name": .string("Window"),
                                           "device_class": .string("window")])
        set("binary_sensor.unavailable", "unavailable", ["friendly_name": .string("Motion"),
                                                         "device_class": .string("motion")])

        set("generic.idle", "idle", ["friendly_name": .string("Thing")])
        set("generic.unavailable", "unavailable", ["friendly_name": .string("Other")])

        set("media_player.playing", "playing", ["friendly_name": .string("Speaker"),
                                                "media_title": .string("A Song"),
                                                "media_artist": .string("An Artist"),
                                                "volume_level": .double(0.4),
                                                "supported_features": .int(4)])
        // A device that declares nothing, which is a real thing a `media_player` does: no title, no
        // transport, and `playPauseButton`'s placeholder glyph where the button would be. The
        // omit-don't-disable rule has no picture without a fixture that has nothing to offer.
        set("media_player.idle", "idle", ["friendly_name": .string("TV")])
        set("media_player.unavailable", "unavailable", ["friendly_name": .string("Radio")])
        // **A player that declares the whole transport.** `media_player.playing` above sets
        // `supported_features: 4` — `volumeSet` alone — so it draws a volume row and *no* live
        // play/pause at all, which was invisible while the 1×1 and 2×1 were the only sizes looked
        // at. `prevNextPlayPause` is play|pause|volumeSet|volumeMute|previousTrack|nextTrack, the
        // set a speaker actually reports, and the 4×1 exists to draw it. The existing fixture keeps
        // its volume-only mask: a player that declares almost nothing is a real device and the only
        // picture of what the 2×1 does with one, so changing it to suit a new rendering would spend
        // the sparse case to gain a duplicate of the rich one. (Its *layout* did change in this
        // commit — `mediaWide` went from a full-width `VStack` to two columns — so what is preserved
        // here is the fixture's state, not an untouched picture.)
        //
        // The title is long on purpose — `ScrollingText` only animates when its content overflows
        // the window, so a short one verifies the still case and nothing else.
        set("media_player.full", "playing",
            ["friendly_name": .string("Kitchen"),
             "media_title": .string("A Song With Rather A Long Name On It"),
             "media_artist": .string("An Artist"),
             "volume_level": .double(0.4),
             "supported_features": .int(Self.prevNextPlayPause)])
        set("media_player.paused", "paused",
            ["friendly_name": .string("Study"),
             "media_title": .string("Another Song"),
             "media_artist": .string("A Second Artist"),
             "volume_level": .double(0.6),
             "supported_features": .int(Self.prevNextPlayPause)])
        // Item 3's hidden-label fixture, and item 2's open question: a player whose name is hidden
        // and which reports no title has nothing at all for the title window. Playing rather than
        // idle, so the blank window sits beside a live transport — which is the comparison being
        // judged. Hidden below, next to `light.unlabelled`.
        set("media_player.nolabel", "playing",
            ["friendly_name": .string("Landing"),
             "volume_level": .double(0.3),
             "supported_features": .int(Self.prevNextPlayPause)])
        // Companion fixtures: entities that share a device_id with a primary and sit at
        // `.companion`, which is what `CompositeState` joins on. Without registry info the resolver
        // correctly finds nothing, and the card would render blank while proving nothing.
        set("binary_sensor.front_contact", "off", ["friendly_name": .string("Door Contact"),
                                                   "device_class": .string("door")])
        set("sensor.front_battery", "88", ["friendly_name": .string("Battery"),
                                           "device_class": .string("battery"),
                                           "unit_of_measurement": .string("%")])
        set("binary_sensor.garage_fully_closed", "on", ["friendly_name": .string("Fully Closed"),
                                                        "device_class": .string("door")])
        set("binary_sensor.garage_fully_open", "unavailable", ["friendly_name": .string("Fully Open"),
                                                               "device_class": .string("door")])
        set("sensor.garage_signal", "-61", ["friendly_name": .string("Signal"),
                                            "unit_of_measurement": .string("dBm")])
        // A relay opener: a *switch* in Home Assistant whose own state says a contact closed, not
        // where the door is. Its limits are the only thing that knows.
        set("switch.opener", "off", ["friendly_name": .string("Garage D")])
        // One limit only, in both directions: half the information is not none of it.
        set("cover.open_only", "open", ["friendly_name": .string("Open only"),
                                        "device_class": .string("garage")])
        set("binary_sensor.open_only_open", "off", ["friendly_name": .string("Fully Open"),
                                                    "device_class": .string("door")])
        set("cover.closed_only", "open", ["friendly_name": .string("Closed only"),
                                          "device_class": .string("garage")])
        set("binary_sensor.closed_only_closed", "off", ["friendly_name": .string("Fully Closed"),
                                                        "device_class": .string("door")])
        set("binary_sensor.opener_closed", "off", ["friendly_name": .string("Fully Closed"),
                                                   "device_class": .string("door")])
        set("binary_sensor.opener_open", "off", ["friendly_name": .string("Fully Open"),
                                                 "device_class": .string("door")])
        // Three garages, all reporting "open" from the cover entity itself — the limits are what
        // tell them apart, which is the point.
        for garage in Self.garages {
            let (id, name, closed, open) = (garage.id, garage.name, garage.closed, garage.open)
            set(id, "open", ["friendly_name": .string(name), "device_class": .string("garage")])
            set("binary_sensor.\(id.split(separator: ".")[1])_closed", closed,
                ["friendly_name": .string("Fully Closed"), "device_class": .string("door")])
            set("binary_sensor.\(id.split(separator: ".")[1])_open", open,
                ["friendly_name": .string("Fully Open"), "device_class": .string("door")])
        }
        // **A room with one of every subsection kind in it**, for the subsection pages. Its own area
        // rather than a reuse of `lounge`: `Subsections.resolve` consumes `room.refs(for:)`, so what
        // a subsection contains is decided by the area's membership *and its curation tiers* — and
        // `lounge`'s sensors are deliberately `.secondary` so the add-a-device picker has something
        // to offer. Bucketed through that room, the Sensors subsection would resolve to nothing at
        // all and look exactly like a container that does not work.
        //
        // Its own entity ids, too, so a device is in exactly one area: `SectionBuilder` builds a
        // room per area from the ids that area lists, and an id in two areas is a tile in two rooms.
        set("climate.sub_a", "heat", ["friendly_name": .string("Lounge"), "temperature": .double(21),
                                      "current_temperature": .double(20.4),
                                      "fan_mode": .string("auto"), "hvac_action": .string("heating"),
                                      "hvac_modes": .array([.string("off"), .string("heat")])])
        // **`current_temperature` on the off thermostat too**, added when climate gained a 4×1. A
        // real thermostat reports the room's temperature whether or not it is heating it, and the
        // 4×1 makes that reading its largest text — so without the attribute page `.climateRows`
        // would draw "—" where the tile's headline goes and verify half of what it renders. The
        // same lesson `media_player.sub_b`'s comment above records. Nothing already on screen moves:
        // `ClimateTile.compact`, which is what every other page draws this fixture at, never reads
        // the attribute at all.
        set("climate.sub_b", "off", ["friendly_name": .string("Study"), "temperature": .double(18),
                                     "current_temperature": .double(19.2),
                                     "hvac_modes": .array([.string("off"), .string("heat")])])
        // Five, so wrap mode actually wraps at four columns and scroll mode actually scrolls.
        for (index, name) in ["Ceiling", "Reading", "Corner", "Shelf", "Desk"].enumerated() {
            set("light.sub_\(index)", index.isMultiple(of: 2) ? "on" : "off",
                ["friendly_name": .string(name)])
        }
        // Three covers, two of them open: the roll-up beside the heading has something to say and
        // its button has something to act on.
        set("cover.sub_a", "open", ["friendly_name": .string("Bay"), "current_position": .int(70)])
        set("cover.sub_b", "closed", ["friendly_name": .string("Side"), "current_position": .int(0)])
        set("cover.sub_c", "open", ["friendly_name": .string("Skylight"), "current_position": .int(40)])
        // **One bare, one full, deliberately paired.** `sub_a` keeps `supported_features: 4`
        // (`volumeSet` alone) as the subsection pages' untouched baseline; `sub_b` declares the whole
        // transport. `.wideRegular` renders this kind at room detail's 4×2, which makes it the only
        // page in the gallery that draws `MediaPlayerTile.large` — and therefore the only picture of
        // both that tile's artwork-scrim transport and its height, the one that used to be a
        // hard-coded 141. With both fixtures declaring volume only, that scrim drew zero buttons and
        // the page verified half of what it renders. `sub_b` had nothing to lose by gaining them: it
        // is idle with no title, so what changes is the controls appearing, not a state moving.
        set("media_player.sub_a", "playing", ["friendly_name": .string("Speaker"),
                                              "media_title": .string("A Song"),
                                              "media_artist": .string("An Artist"),
                                              "volume_level": .double(0.4),
                                              "supported_features": .int(4)])
        set("media_player.sub_b", "idle", ["friendly_name": .string("TV"),
                                           "supported_features": .int(Self.prevNextPlayPause)])
        // The cameras page is deterministic despite the header comment above: these fixtures have no
        // registry entry and the gallery's `AppModel` has no session, so `AuthenticatedImage` fails
        // its load immediately and every render is the same placeholder. What is being looked at
        // here is the *container* — a 2×2 in a scroll row against a 2×2 in the grid — not a picture.
        set("camera.sub_a", "recording", ["friendly_name": .string("Front Door")])
        set("camera.sub_b", "idle", ["friendly_name": .string("Driveway")])
        set("scene.sub_a", "scening", ["friendly_name": .string("Movie Night")])
        set("lock.sub_a", "locked", ["friendly_name": .string("Patio")])
        set("switch.sub_a", "on", ["friendly_name": .string("Lamp Socket")])
        // **Power and energy, not temperature or humidity.** A temperature sensor is uplifted into
        // the room's environment chips and never reaches a subsection at all (see
        // `SectionBuilder.rooms`), so it cannot show what a Sensors subsection does with its members.
        set("sensor.sub_power", "63", ["friendly_name": .string("Power"),
                                       "device_class": .string("power"),
                                       "unit_of_measurement": .string("W")])
        set("sensor.sub_energy", "4.2", ["friendly_name": .string("Energy"),
                                         "device_class": .string("energy"),
                                         "unit_of_measurement": .string("kWh")])
        set("binary_sensor.sub_door", "on", ["friendly_name": .string("Door"),
                                             "device_class": .string("door")])
        set("binary_sensor.sub_motion", "off", ["friendly_name": .string("Motion"),
                                                "device_class": .string("motion")])

        store.home = ResolvedHome(floors: [ResolvedFloor(id: "f", name: "Ground", level: 0, areas: [
            // Tiers spelled out rather than left to `tier(of:)`'s `.primary` fallback: a sensor is
            // `.secondary` in a real home (see `EntityCuration`), and with everything `.primary` the
            // dashboard would already be showing it all — leaving the add-a-device picker with
            // nothing to offer, which is exactly what the first render of this page showed.
            ResolvedArea(id: "lounge", name: "Lounge",
                         entityIds: ["sensor.lounge_temp", "sensor.lounge_temp_window",
                                     "sensor.lounge_hum", "sensor.lounge_hum_2"],
                         tiers: ["sensor.lounge_temp": .secondary,
                                 "sensor.lounge_temp_window": .secondary,
                                 "sensor.lounge_hum": .secondary,
                                 "sensor.lounge_hum_2": .secondary]),
            ResolvedArea(id: "hall", name: "Hall", entityIds: [], tiers: [:]),
            // The composite fixtures. `.companion` is the tier `EntityCuration`'s container rule
            // produces and that no surface rendered until `DeviceContextCard`.
            ResolvedArea(id: "doors", name: "Doors",
                         entityIds: ["lock.locked", "binary_sensor.front_contact",
                                     "sensor.front_battery", "cover.open",
                                     "binary_sensor.garage_fully_closed",
                                     "binary_sensor.garage_fully_open", "sensor.garage_signal"],
                         tiers: ["lock.locked": .primary,
                                 "binary_sensor.front_contact": .companion,
                                 "sensor.front_battery": .companion,
                                 "cover.open": .primary,
                                 "binary_sensor.garage_fully_closed": .companion,
                                 "binary_sensor.garage_fully_open": .companion,
                                 "sensor.garage_signal": .companion]),
            // Every tier spelled out as `.primary`, including the sensors: `refs(for: .overview)`
            // filters by tier, and a `.secondary` sensor is off the dashboard by curation — which
            // is right for a real home and would leave the Sensors subsection empty here.
            //
            // Interleaved rather than grouped by domain: the bucketing preserves the room's order
            // within a kind, so a sensor and a binary sensor sitting next to each other in the
            // Sensors subsection is a fact about this list.
            ResolvedArea(id: "subs", name: "Every Kind",
                         entityIds: Self.subsectionEntityIds,
                         tiers: Dictionary(uniqueKeysWithValues:
                            Self.subsectionEntityIds.map { ($0, CurationTier.primary) })),
        ])],
        // Two devices: the front door's lock with its contact and battery, and the garage cover
        // with its two limit sensors and a signal reading. `light.on` deliberately has no device at
        // all, which is the case that must render nothing.
        registryInfo: [
            "lock.locked": EntityRegistryInfo(platform: nil, uniqueId: nil, deviceId: "front-door"),
            "binary_sensor.front_contact": EntityRegistryInfo(platform: nil, uniqueId: nil, deviceId: "front-door"),
            "sensor.front_battery": EntityRegistryInfo(platform: nil, uniqueId: nil, deviceId: "front-door"),
            "cover.open": EntityRegistryInfo(platform: nil, uniqueId: nil, deviceId: "garage"),
            "binary_sensor.garage_fully_closed": EntityRegistryInfo(platform: nil, uniqueId: nil, deviceId: "garage"),
            "binary_sensor.garage_fully_open": EntityRegistryInfo(platform: nil, uniqueId: nil, deviceId: "garage"),
            "sensor.garage_signal": EntityRegistryInfo(platform: nil, uniqueId: nil, deviceId: "garage"),
        ])
        store.resolveEnvironment()
        var document = store.config.document
        // Item 2 (tile-refinements): `light.unlabelled` has its name hidden, so `.first`'s Light
        // row (`ids("light", [...])` above) shows one nameless tile beside labelled siblings.
        document = document.settingLabelHidden(true, entityId: "light.unlabelled")
        // Item 3's own hidden-label case, on page `.ninth`: the same household choice on a media
        // player, where it lands on the title window's name-fallback rather than on a name row.
        document = document.settingLabelHidden(true, entityId: "media_player.nolabel")
        // The label-style twins: the same states again, with the household's choice stored, so both
        // styles can be compared rather than described.
        for (id, state, name, dc) in [
            ("binary_sensor.active_l", "on", "Door", "door"),
            ("binary_sensor.clear_l", "off", "Window", "window"),
            ("binary_sensor.unavailable_l", "unavailable", "Motion", "motion"),
            ("lock.locked_l", "locked", "Front", nil),
            ("lock.unlocked_l", "unlocked", "Back", nil),
            ("lock.jammed_l", "jammed", "Side", nil),
            ("lock.unavailable_l", "unavailable", "Shed", nil),
            ("cover.open_l", "open", "Blinds", nil),
            ("cover.closed_l", "closed", "Garage", "garage"),
            ("switch.on_l", "on", "Fan", nil),
            ("switch.off_l", "off", "Heater", "outlet"),
            ("switch.unavailable_l", "unavailable", "Pump", nil),
            ("cover.unavailable_l", "unavailable", "Awning", nil),
            ("light.on_l", "on", "Kitchen", nil),
            ("light.off_l", "off", "Hallway", nil),
            ("light.unavailable_l", "unavailable", "Porch", nil),
        ] as [(String, String, String, String?)] {
            var attrs: [String: JSONValue] = ["friendly_name": .string(name)]
            if let dc { attrs["device_class"] = .string(dc) }
            store.states[id] = EntityState(entityId: id, state: state, attributes: attrs,
                                           lastUpdated: Date(timeIntervalSince1970: 0))
            document = document.settingStateStyle(.label, for: id)
        }
        // Each garage is a *device* of type `garage_door` whose primary is the cover — which is
        // what choosing that type in the `+` flow creates — with its limits as inputs.
        for garage in Self.garages {
            let stem = String(garage.id.split(separator: ".")[1])
            document = document.settingDevice(
                DashboardDocument.StoredDevice(
                    id: garage.id, type: "garage_door", areaId: "lounge",
                    inputs: [.primary: [garage.id],
                             .closedLimit: ["binary_sensor.\(stem)_closed"],
                             .openLimit: ["binary_sensor.\(stem)_open"]]),
                id: garage.id)
        }
        document = document.settingDevice(
            DashboardDocument.StoredDevice(
                id: "switch.opener", type: "garage_door", areaId: "lounge",
                inputs: [.primary: ["switch.opener"],
                         .closedLimit: ["binary_sensor.opener_closed"],
                         .openLimit: ["binary_sensor.opener_open"]]),
            id: "switch.opener")
        for (id, role, sensor) in [("cover.open_only", DeviceRole.openLimit, "binary_sensor.open_only_open"),
                                   ("cover.closed_only", DeviceRole.closedLimit, "binary_sensor.closed_only_closed")] {
            document = document.settingDevice(
                DashboardDocument.StoredDevice(id: id, type: "garage_door", areaId: "lounge",
                                               inputs: [.primary: [id], role: [sensor]]),
                id: id)
        }
        store.config.seedForTesting(document)

        // Seeded history, so the sparkline can be looked at without a server. A gentle curve and a
        // spiky one, because the two are what the y-domain choice is about: a room that moved half a
        // degree all day must still show its shape rather than a flat line against a zero baseline.
        let origin = Date(timeIntervalSince1970: 0)
        func seed(_ id: String, _ values: [Double]) {
            let points = values.enumerated().map {
                HistoryPoint(time: origin.addingTimeInterval(Double($0.offset) * 3600), value: $0.element)
            }
            store.historyCache.byKey[HomeStore.historyKey(id, .day, nil)] = (HistorySeries(points: points), origin)
        }
        seed("sensor.value", [20.8, 20.9, 21.2, 21.6, 21.4, 21.1, 20.9, 21.0, 21.3, 21.5, 21.4, 21.4])
        seed("sensor.spiky", [4, 6, 5, 210, 180, 12, 8, 7, 240, 190, 15, 63])
        // Both subsection sensors have history: a Sensors subsection set to 2×1 is the open question
        // those pages exist to answer, and an unseeded sensor renders the no-line case instead —
        // which would be a different question answered by accident.
        seed("sensor.sub_power", [4, 6, 5, 210, 180, 12, 8, 7, 240, 190, 15, 63])
        seed("sensor.sub_energy", [0.2, 0.6, 1.1, 1.4, 1.9, 2.3, 2.8, 3.1, 3.4, 3.8, 4.0, 4.2])
        // `sensor.nohistory` and `sensor.text` are deliberately left unseeded.
        return store
    }
}

#Preview("Tiles 1 — light, switch, cover, lock") {
    TileGallery(page: .first)
}

#Preview("Tiles 2 — scene, sensor, binary, generic") {
    TileGallery(page: .second)
}

/// Climate gets a page to itself: eight fixtures at double width is more than fits beside anything
/// else, and every one of them is a distinct colour or state rule.
#Preview("Tiles 3 — climate") {
    TileGallery(page: .third)
}

/// The configuration sheets, which have no other verification.
#Preview("Tiles 4 — configuration") {
    TileGallery(page: .fourth)
}

/// Its own page: page four was already two full sheets, and a page that overflows has stopped being
/// a baseline — the same reason climate's eight fixtures forced a third.
#Preview("Tiles 5 — add a device") {
    TileGallery(page: .fifth)
}

#Preview("Tiles 6 — two-state styles") {
    TileGallery(page: .sixth)
}

#Preview("Tiles 7 — climate 4×2") {
    TileGallery(page: .seventh)
}

#Preview("Tiles 8 — what else a device knows") {
    TileGallery(page: .eighth)
}

/// Media's own page, for the reason climate got one: the 4×1 needs five fixtures at full width, and
/// page two was already full. The 4×2 is not here — it renders at a real cell height on
/// `.wideRegular`, which is where its own height fix is looked at.
#Preview("Tiles 9 — media 2×1 and 4×1") {
    TileGallery(page: .ninth)
}

/// Climate's second page, for the reason it got its first: page three is eight fixtures at double
/// width and page seven is three 4×2s at a real cell height, and five full-width rows fit under
/// neither. The 2×1 and the 4×2 are not repeated here — see `climateRow4x1` for what these five
/// states are chosen to show.
#Preview("Tiles 10 — climate 4×1") {
    TileGallery(page: .tenth)
}

/// **The subsection container, which both surfaces now render** — this is where its looks are
/// checked, away from a real home's contents. Eight pages rather than one: seven kinds in two modes
/// at two densities is twenty-eight renderings before any non-default span is looked at, and this
/// file's standing rule is that a page which overflows has stopped being a baseline. Three of the
/// eight exist for a non-default span alone — sensors at 2×1, and the two kinds that offer a 4×1.
///
/// Each page puts a kind's two modes one above the other, because the claim being checked is that
/// the mode changes where the tiles are and not how wide they are — see `subsectionPage(_:_:)` for
/// what that comparison does and does not guarantee about their heights.
#Preview("Subsections 1 — 1×1 kinds, floor") {
    TileGallery(page: .narrowCompact)
}

#Preview("Subsections 2 — 1×1 kinds, room detail") {
    TileGallery(page: .narrowRegular)
}

#Preview("Subsections 3 — wide kinds, floor") {
    TileGallery(page: .wideCompact)
}

/// The tall one, unavoidably: room detail gives media and cameras the full four columns, so two of
/// either is two grid rows and there is no shorter honest rendering of it.
#Preview("Subsections 4 — wide kinds, room detail") {
    TileGallery(page: .wideRegular)
}

/// The 2×1 sensors question — see `sensorSubsections`.
#Preview("Subsections 5 — sensors, 1×1 against 2×1") {
    TileGallery(page: .sensors)
}

/// The 4×1 media question — see `mediaRowSubsections`. A span no default reaches, in the container
/// that decides how tall it is.
#Preview("Subsections 6 — media, 4×1") {
    TileGallery(page: .mediaRows)
}

/// The 4×1 climate question — see `climateRowSubsections`. Its own page beside the media one for
/// the reason that one is its own page: two kinds at two modes will not share a screen.
#Preview("Subsections 7 — climate, 4×1") {
    TileGallery(page: .climateRows)
}

#Preview("Subsections 8 — configuring") {
    TileGallery(page: .configuring)
}
#endif
