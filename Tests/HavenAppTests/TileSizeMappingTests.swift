import Testing
import HavenCore
@testable import HavenApp

/// **The other half of "nothing is listed that cannot be drawn."**
///
/// `TileSpan.available(for:)` says which sizes a household may pick, and Core's
/// `everyDomainOffersOnlyTheSizesSomethingCanDraw` pins that list. What no test reached until now is
/// the *other* side of the same sentence: the four `init(span:)` mappings that turn one of those
/// spans into an actual rendering. Between them they are, as `DeviceTileView.tile` puts it, the one
/// place where a number of cells becomes a drawing — and all four lived unverified.
///
/// That gap had already cost something. `ClimateTileSize(span:)` was `span.columns >= 4 ? .large :
/// .compact` — a test on the *width alone*, which was correct for exactly as long as four columns
/// meant two rows. The moment climate was offered a 4×1 (tile refinements, item 4), that expression
/// would have sent it to `.large`: a three-row `VStack` inside a tile one row tall, on every
/// dashboard that picked the new size. It was found by reading the mapping before changing the list,
/// which is not a method that scales — `CameraTileSize` and `SensorTileSize` are still one-sided
/// width tests today, and will spring the same trap the day either list grows a row.
///
/// These tests are deliberately about *all four* domains rather than the one that just changed. A
/// mapping is cheap to pin and the failure mode is invisible until somebody looks at a device.
@Suite struct TileSizeMappingTests {

    /// **Offering two sizes that render identically is offering one size twice.**
    ///
    /// The size picker shows a chip per entry in `available(for:)`, so a household choosing between
    /// them is being told the choice does something. If two spans map to the same case, one chip is
    /// a lie: the tile keeps its shape, the stored document changes, and the grid re-flows the cell
    /// around a rendering that did not move. That is not hypothetical — it is exactly how the 4×1
    /// would have arrived, as a second, wider way to ask for `.large`.
    ///
    /// Stated as an invariant over the offered list rather than as a count per domain, so it holds
    /// for whatever the lists become. It is the one assertion here that a *new* entry cannot pass by
    /// accident: adding a span without adding a case fails this, whether or not anybody remembers to
    /// write a literal for it below.
    @Test func everyOfferedSizeDrawsADifferentRendering() {
        expectDistinctRenderings(.climate, ClimateTileSize.init(span:))
        expectDistinctRenderings(.mediaPlayer, MediaTileSize.init(span:))
        expectDistinctRenderings(.camera, CameraTileSize.init(span:))
        expectDistinctRenderings(.sensor, SensorTileSize.init(span:))
    }

    /// Every offered span against the rendering its list promises, written out.
    ///
    /// The distinctness invariant above catches a span that draws nothing new; this catches a span
    /// that draws the *wrong* thing — two spans can be perfectly distinct and still be swapped. The
    /// literals are the record of which is which, and they are grouped per domain in the same
    /// ascending order `available(for:)` lists them, so the two can be read side by side.
    @Test func everyOfferedSpanDrawsTheRenderingItsListPromises() {
        // Climate: the readout with two controls squeezed beside it, that readout given a whole
        // line, then the sheet's controls without the sheet.
        #expect(ClimateTileSize(span: TileSpan(columns: 2, rows: 1)) == .compact)
        #expect(ClimateTileSize(span: TileSpan(columns: 4, rows: 1)) == .row)
        #expect(ClimateTileSize(span: TileSpan(columns: 4, rows: 2)) == .large)
        // Media: the scrolling title with play/pause, that title with a real transport beside it,
        // then artwork and volume.
        #expect(MediaTileSize(span: TileSpan(columns: 2, rows: 1)) == .wide)
        #expect(MediaTileSize(span: TileSpan(columns: 4, rows: 1)) == .row)
        #expect(MediaTileSize(span: TileSpan(columns: 4, rows: 2)) == .large)
        // Camera: the still over a caption strip, then full-bleed.
        #expect(CameraTileSize(span: TileSpan(columns: 2, rows: 2)) == .square)
        #expect(CameraTileSize(span: TileSpan(columns: 4, rows: 2)) == .wide)
        // Sensor: a reading, then a reading over a day of itself.
        #expect(SensorTileSize(span: TileSpan(columns: 1, rows: 1)) == .small)
        #expect(SensorTileSize(span: TileSpan(columns: 2, rows: 1)) == .wide)
    }

    /// **A span that is not on offer still has to draw something**, and every one of these mappings
    /// answers with its smallest rendering rather than refusing.
    ///
    /// This is not a theoretical branch. A household that stored a size under an older build holds a
    /// span the current list no longer contains — media's 1×1 is the standing example, withdrawn in
    /// item 3 of the same batch — and that document is a decision Haven revised, not one to discard.
    /// `MediaTileSize(span:)` documents this fallback at length and nothing pinned it until now,
    /// which is the combination that lets a documented behaviour quietly stop being true.
    ///
    /// Each domain is probed with a span it does not offer: 1×1 for the three that have no
    /// one-column size, and 4×2 for sensors, which is the opposite direction — a span too *large*
    /// falls back the same way, because the rule is "the rendering that fits anywhere", not "the
    /// nearest one".
    @Test func aSpanThatIsNotOnOfferFallsBackToTheSmallestRendering() {
        let oneByOne = TileSpan(columns: 1, rows: 1)
        #expect(!TileSpan.available(for: .climate).contains(oneByOne))
        #expect(ClimateTileSize(span: oneByOne) == .compact)
        // The withdrawn size itself, not merely an unoffered one: this is what a document written
        // before item 3 actually holds.
        #expect(!TileSpan.available(for: .mediaPlayer).contains(oneByOne))
        #expect(MediaTileSize(span: oneByOne) == .wide)
        #expect(!TileSpan.available(for: .camera).contains(oneByOne))
        #expect(CameraTileSize(span: oneByOne) == .square)
        let fourByTwo = TileSpan(columns: 4, rows: 2)
        #expect(!TileSpan.available(for: .sensor).contains(fourByTwo))
        #expect(SensorTileSize(span: fourByTwo) == .wide)
    }

    /// Every span a domain offers, mapped, must yield as many distinct renderings as there were
    /// spans.
    ///
    /// Generic over the enum rather than repeated four times, because the claim is one claim. The
    /// `Hashable` requirement costs nothing: all four are enums without associated values, so Swift
    /// synthesises `Equatable` and `Hashable` for them with no declaration on any of the types —
    /// verified by this file compiling, not assumed.
    private func expectDistinctRenderings<Size: Hashable>(_ domain: Domain,
                                                          _ rendering: (TileSpan) -> Size) {
        let offered = TileSpan.available(for: domain)
        let drawn = Set(offered.map(rendering))
        // A single interpolated literal rather than a concatenation: `#expect`'s second parameter is
        // a `Comment`, which is `ExpressibleByStringInterpolation` but not built from a `String`.
        #expect(drawn.count == offered.count,
                "\(domain) offers \(offered.count) sizes that draw only \(drawn.count) renderings — at least two chips in its size picker do the same thing")
    }
}
