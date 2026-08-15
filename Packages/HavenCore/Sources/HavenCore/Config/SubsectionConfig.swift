import Foundation

/// `DashboardDocument`'s subsection settings: the household's per-kind size and display mode, and
/// its global default display mode.
///
/// A separate file rather than a `MARK` in `DashboardDocument.swift` because Task 1 landed
/// `SubsectionKind`/`SubsectionMode` in `Curation/Subsection.swift`, and this is the persistence
/// half of that type — same split as `SubsectionTests.swift` already keeps from
/// `DashboardDocumentTests.swift`.
///
/// Every accessor and mutator here follows the same discipline the rest of the document does — see
/// `DashboardDocument`'s own doc comment: read-merge-write on `raw.asObject`, touching only the
/// subtree owned here, so a build that has never heard of subsections still round-trips one
/// unchanged.
extension DashboardDocument {
    private static let displayKey = "display"
    private static let subsectionsKey = "subsections"
    private static let modeKey = "mode"
    private static let sizeKey = "size"
    /// Duplicated from `DashboardDocument`'s own private constant rather than shared: `private` in
    /// an extension is scoped to the file it appears in, and this extension lives in a different
    /// file from the type's primary declaration.
    private static let schemaKey = "schema"

    // MARK: - Household display mode

    /// The household's chosen default display mode, applied to every subsection that has not
    /// overridden it — the middle link in the fallback chain override → global default → built-in
    /// `scroll` that `Subsections.resolve` walks. `nil` when nobody has chosen one.
    ///
    /// A separate top-level object rather than a pseudo-kind inside `subsections`, so
    /// `SubsectionKind` stays a closed enum with nothing to disambiguate from a household-wide
    /// setting — see the schema section of the design doc.
    public var displayMode: SubsectionMode? {
        raw.asObject?[Self.displayKey]?.asObject?[Self.modeKey]?.asString
            .flatMap(SubsectionMode.init(rawValue:))
    }

    /// This document with the household default display mode set, or — for `nil` — cleared back to
    /// the built-in default.
    public func settingDisplayMode(_ mode: SubsectionMode?) -> DashboardDocument {
        var root = raw.asObject ?? [:]
        root[Self.schemaKey] = .int(max(declaredSchema, Self.schema))
        var display = root[Self.displayKey]?.asObject ?? [:]
        if let mode {
            display[Self.modeKey] = .string(mode.rawValue)
        } else {
            display.removeValue(forKey: Self.modeKey)
        }
        // An empty `display` object is removed outright, so clearing the only setting it ever held
        // leaves the document exactly as it started rather than a permanent empty shell.
        if display.isEmpty {
            root.removeValue(forKey: Self.displayKey)
        } else {
            root[Self.displayKey] = .object(display)
        }
        return DashboardDocument(raw: .object(root))
    }

    // MARK: - Per-subsection size and mode

    /// This kind's chosen tile span, or `nil` when the household hasn't set one — the default from
    /// `SubsectionKind.defaultSpan(on:)` applies instead.
    ///
    /// **A garbage or unreadable stored size reads as `nil`, not a crash or a guess** — the same
    /// discipline `tileSizes` already holds for per-entity sizes: a build that knows a shape this
    /// one does not must leave this one working rather than claim the household chose something it
    /// cannot draw.
    public func subsectionSpan(_ kind: SubsectionKind) -> TileSpan? {
        guard let stored = raw.asObject?[Self.subsectionsKey]?.asObject?[kind.rawValue]?.asObject?[Self.sizeKey]?.asString
        else { return nil }
        return TileSpan(stored: stored)
    }

    /// This kind's chosen display mode override, or `nil` when it follows `displayMode`.
    public func subsectionMode(_ kind: SubsectionKind) -> SubsectionMode? {
        raw.asObject?[Self.subsectionsKey]?.asObject?[kind.rawValue]?.asObject?[Self.modeKey]?.asString
            .flatMap(SubsectionMode.init(rawValue:))
    }

    /// This document with one kind's tile span set, or — for `nil` — cleared back to its default.
    ///
    /// Merges at every level so a sibling kind's settings, and this kind's own `mode`, survive a
    /// span write untouched — modelled line-for-line on `settingDevice`/`settingSize`.
    public func settingSubsectionSpan(_ span: TileSpan?, kind: SubsectionKind) -> DashboardDocument {
        var root = raw.asObject ?? [:]
        root[Self.schemaKey] = .int(max(declaredSchema, Self.schema))
        var subsections = root[Self.subsectionsKey]?.asObject ?? [:]
        var section = subsections[kind.rawValue]?.asObject ?? [:]
        if let span {
            section[Self.sizeKey] = .string(span.stored)
        } else {
            section.removeValue(forKey: Self.sizeKey)
        }
        Self.storeSection(section, forKind: kind, into: &subsections)
        Self.storeSubsections(subsections, into: &root)
        return DashboardDocument(raw: .object(root))
    }

    /// This document with one kind's display mode override set, or — for `nil` — cleared back to
    /// following `displayMode`.
    ///
    /// Merges at every level for the same reason `settingSubsectionSpan` does: a sibling kind, and
    /// this kind's own `size`, must survive a mode write untouched.
    public func settingSubsectionMode(_ mode: SubsectionMode?, kind: SubsectionKind) -> DashboardDocument {
        var root = raw.asObject ?? [:]
        root[Self.schemaKey] = .int(max(declaredSchema, Self.schema))
        var subsections = root[Self.subsectionsKey]?.asObject ?? [:]
        var section = subsections[kind.rawValue]?.asObject ?? [:]
        if let mode {
            section[Self.modeKey] = .string(mode.rawValue)
        } else {
            section.removeValue(forKey: Self.modeKey)
        }
        Self.storeSection(section, forKind: kind, into: &subsections)
        Self.storeSubsections(subsections, into: &root)
        return DashboardDocument(raw: .object(root))
    }

    /// Writes one kind's section back into `subsections`, or removes it — an empty section is
    /// residue, not a decision anyone made, exactly as an empty entity record is elsewhere in this
    /// document.
    ///
    /// Every sibling mutator in `DashboardDocument.swift` inlines this write-back-or-remove step
    /// rather than factoring it out — including three-level merges of the identical shape:
    /// `settingSize` (`:234-260`) and `settingMembership` (`:419-445`) each repeat it once per
    /// level, three times over. This file factors it instead because both settings here
    /// (`settingSubsectionSpan` and `settingSubsectionMode`) walk the *exact same* two-level subtree
    /// — kind-section, then `subsections` root — so the duplication would be between them as well as
    /// within each, not because no inlined precedent exists.
    private static func storeSection(_ section: [String: JSONValue], forKind kind: SubsectionKind,
                                     into subsections: inout [String: JSONValue]) {
        if section.isEmpty {
            subsections.removeValue(forKey: kind.rawValue)
        } else {
            subsections[kind.rawValue] = .object(section)
        }
    }

    /// Writes `subsections` back into the document root, or removes the key entirely once the last
    /// kind's settings have been cleared.
    private static func storeSubsections(_ subsections: [String: JSONValue], into root: inout [String: JSONValue]) {
        if subsections.isEmpty {
            root.removeValue(forKey: subsectionsKey)
        } else {
            root[subsectionsKey] = .object(subsections)
        }
    }
}
