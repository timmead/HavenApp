import Foundation

/// One subsection, fully decided: which devices it holds, in what order, at what size, laid out how.
///
/// What a container renders — `SubsectionView` reads this and nothing else, so a rendering
/// bug in a container can never be "the resolver forgot something": the fields here are the whole
/// contract.
public struct RoomSubsection: Sendable, Equatable, Identifiable {
    public let kind: SubsectionKind
    public let refs: [DeviceRef]
    public let span: TileSpan
    public let mode: SubsectionMode
    public var id: String { kind.rawValue }
}

/// Buckets a room's devices into its subsections.
public enum Subsections {
    /// The order subsections render in: **climate, lights, shades, cameras, media, other, sensors —
    /// cameras before media.**
    ///
    /// A fixed array, deliberately not `SubsectionKind.allCases`. `allCases` follows the enum's
    /// declaration order, which matches the schema listing (media before cameras, decision 1 in the
    /// design doc) — a different concern from the on-screen order the design approved in decision 7.
    /// Spelling this out separately means a case added to the enum tomorrow does not silently
    /// reorder the screen; it has to be added here too, deliberately.
    private static let order: [SubsectionKind] = [
        .climate, .lights, .shades, .cameras, .media, .other, .sensors,
    ]

    /// Pure function of its inputs, same shape as `RegistryResolver`.
    ///
    /// Consumes `room.refs(for: surface)` — already filtered by membership and curation tier, and
    /// already in the household's arranged order — so this does none of that filtering itself; it
    /// only buckets that list by `SubsectionKind.of(_:)`, drops the kinds nobody has anything in, and
    /// reads each surviving kind's span and mode.
    ///
    /// A ref whose `primaryEntityId` is `nil` is skipped rather than bucketed — mirrors
    /// `SubsectionView`'s own handling of the same case (a stored composite whose primary
    /// vanished; `DashboardDocument.devices` already drops those in practice, but the resolver does
    /// not assume it).
    public static func resolve(room: RoomSection, surface: HavenSurface,
                               document: DashboardDocument) -> [RoomSubsection] {
        var buckets: [SubsectionKind: [DeviceRef]] = [:]
        for ref in room.refs(for: surface) {
            guard let primary = ref.primaryEntityId else { continue }
            buckets[SubsectionKind.of(primary), default: []].append(ref)
        }
        return order.compactMap { kind in
            guard let refs = buckets[kind], !refs.isEmpty else { return nil }
            let mode = document.subsectionMode(kind) ?? document.displayMode ?? .scroll
            let span = document.subsectionSpan(kind) ?? kind.defaultSpan(on: surface)
            return RoomSubsection(kind: kind, refs: refs, span: span, mode: mode)
        }
    }
}
