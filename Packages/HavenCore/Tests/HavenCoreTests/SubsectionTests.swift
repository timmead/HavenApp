import Foundation
import Testing
@testable import HavenCore

// The bucketing rule: which subsection an entity's primary lands in. Moved from
// `RoomDetailView.grouped`, where nothing could test it.
@Test func everyDomainBucketsWhereTheDetailViewPutIt() {
    #expect(SubsectionKind.of("climate.hall") == .climate)
    #expect(SubsectionKind.of("light.kitchen") == .lights)
    #expect(SubsectionKind.of("cover.blind") == .shades)
    #expect(SubsectionKind.of("media_player.tv") == .media)
    #expect(SubsectionKind.of("camera.front") == .cameras)
    #expect(SubsectionKind.of("scene.movie") == .other)
    #expect(SubsectionKind.of("script.night") == .other)
    #expect(SubsectionKind.of("lock.front") == .other)
    #expect(SubsectionKind.of("switch.pump") == .other)
    #expect(SubsectionKind.of("sensor.temp") == .sensors)
    #expect(SubsectionKind.of("binary_sensor.door") == .sensors)
    #expect(SubsectionKind.of("garbage.x") == .other)   // Domain.unknown
}

/// Default spans are exactly today's `TileSpan.default` values, so an unconfigured document
/// renders exactly today's proportions — the spec's compatibility promise.
@Test func defaultSpansMatchTheDomainDefaultsTheyReplace() {
    for surface in HavenSurface.allCases {
        #expect(SubsectionKind.climate.defaultSpan(on: surface) == TileSpan.default(for: .climate, on: surface))
        #expect(SubsectionKind.lights.defaultSpan(on: surface) == TileSpan.default(for: .light, on: surface))
        #expect(SubsectionKind.shades.defaultSpan(on: surface) == TileSpan.default(for: .cover, on: surface))
        #expect(SubsectionKind.media.defaultSpan(on: surface) == TileSpan.default(for: .mediaPlayer, on: surface))
        #expect(SubsectionKind.cameras.defaultSpan(on: surface) == TileSpan.default(for: .camera, on: surface))
        #expect(SubsectionKind.other.defaultSpan(on: surface) == TileSpan(columns: 1, rows: 1))
        #expect(SubsectionKind.sensors.defaultSpan(on: surface) == TileSpan(columns: 1, rows: 1))
    }
}

/// The size picker's option list per kind. Every offered span must be drawable by the kind's
/// *most capable* member (`TileSpan.available`), because subsection sizing is uniform: a kind
/// whose members disagree offers only what the least capable can occupy without a bespoke
/// rendering — the existing smallest-rendering fallback covers the rest.
@Test func offeredSpansComeFromTheMembersRealRenderings() {
    #expect(SubsectionKind.lights.availableSpans == [TileSpan(columns: 1, rows: 1)])
    #expect(SubsectionKind.other.availableSpans == [TileSpan(columns: 1, rows: 1)])
    #expect(SubsectionKind.sensors.availableSpans == TileSpan.available(for: .sensor))
    #expect(SubsectionKind.climate.availableSpans == TileSpan.available(for: .climate))
    #expect(SubsectionKind.media.availableSpans == TileSpan.available(for: .mediaPlayer))
    #expect(SubsectionKind.cameras.availableSpans == TileSpan.available(for: .camera))
}

/// The config sheet's picker (`TileSizePicker(options: kind.availableSpans, selection:
/// sizeSelection)`) seeds `span` from `defaultSpan(on:)` when nothing is stored — see
/// `SubsectionConfigView.span`'s `onAppear`. `sizeSelection` reads `nil` — no chip checked — as
/// the picker's own legitimate value for "Follow" (follow-up 4), so if a kind's default ever fell
/// outside its own offered sizes, the seed would not read as visibly broken: a `span` no chip
/// matches renders identically to `nil`, so the sheet would open *masquerading as Follow chosen*
/// for a household that has configured nothing and never touched that row.
@Test func defaultSpanIsAlwaysAnOfferedSize() {
    for kind in SubsectionKind.allCases {
        for surface in HavenSurface.allCases {
            #expect(kind.availableSpans.contains(kind.defaultSpan(on: surface)))
        }
    }
}

@Test func storedRawValuesAreTheSchemaVocabulary() {
    #expect(SubsectionKind.allCases.map(\.rawValue)
            == ["climate", "lights", "shades", "media", "cameras", "other", "sensors"])
    #expect(SubsectionMode.scroll.rawValue == "scroll")
    #expect(SubsectionMode.wrap.rawValue == "wrap")
}
