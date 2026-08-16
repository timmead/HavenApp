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

    /// This kind's chosen tile span **on one surface**, or `nil` when the household hasn't set one
    /// for it there. The caller resolves the rest of the chain — own surface → other surface →
    /// `SubsectionKind.defaultSpan(on:)` — at read time, in `Subsections.resolve`; this accessor
    /// only ever answers for the one surface it was asked about.
    ///
    /// **Decision 10** (Task 6's review): `size` was one string per kind, and that flattened the
    /// per-surface defaults the schema itself declares — cameras and media render differently sized
    /// on the two surfaces by default, and any explicit choice erased that distinction on both at
    /// once. `size` is now an object keyed by `HavenSurface.rawValue`, the same shape decision 9
    /// gave `order`.
    ///
    /// **A document still carrying the old single-string `size` reads as `nil` here** — `.asObject`
    /// simply does not match a `.string`, so the legacy shape falls out the same way a garbage or
    /// unreadable value would, the discipline `surfaceOverrides` already holds for values it cannot
    /// read. Nothing has shipped, so nothing migrates: a development document reverts to the
    /// per-surface default once, silently, and that is a smaller cost than a migration nobody will
    /// need again.
    public func subsectionSpan(_ kind: SubsectionKind, on surface: HavenSurface) -> TileSpan? {
        guard let stored = raw.asObject?[Self.subsectionsKey]?.asObject?[kind.rawValue]?.asObject?[Self.sizeKey]?
            .asObject?[surface.rawValue]?.asString
        else { return nil }
        return TileSpan(stored: stored)
    }

    /// This kind's chosen display mode override, or `nil` when it follows `displayMode`.
    public func subsectionMode(_ kind: SubsectionKind) -> SubsectionMode? {
        raw.asObject?[Self.subsectionsKey]?.asObject?[kind.rawValue]?.asObject?[Self.modeKey]?.asString
            .flatMap(SubsectionMode.init(rawValue:))
    }

    /// This document with one kind's tile span **on one surface** set, or — for `nil` — cleared back
    /// to unset on that surface.
    ///
    /// **The sibling surface's span is untouched**, the same merge discipline `settingOrder` holds
    /// for decision 9 and for the identical reason: the two surfaces are sized independently, so a
    /// write that replaced the whole `size` object would make choosing a camera size on the floor
    /// silently discard whatever room detail had chosen. Merges at every other level too, so a
    /// sibling *kind*'s settings and this kind's own `mode` also survive untouched — modelled on
    /// `settingDevice`/`settingMembership`, the way the single-surface version of this function was.
    ///
    /// A surface key holding nothing is removed, and a `size` holding no surfaces is removed with
    /// it — no `"size": {}` husk left for `storeSection` below to trip over, mirroring
    /// `settingOrder`'s identical cleanup for `order`.
    ///
    /// `section[Self.sizeKey]?.asObject` also swallows the legacy single-string shape: a document
    /// still carrying the old `size` reads as unset here on the write side too, so the first
    /// per-surface write after this change replaces it outright rather than merging into a shape it
    /// cannot understand.
    public func settingSubsectionSpan(_ span: TileSpan?, kind: SubsectionKind,
                                      on surface: HavenSurface) -> DashboardDocument {
        var root = raw.asObject ?? [:]
        root[Self.schemaKey] = .int(max(declaredSchema, Self.schema))
        var subsections = root[Self.subsectionsKey]?.asObject ?? [:]
        var section = subsections[kind.rawValue]?.asObject ?? [:]
        var bySurface = section[Self.sizeKey]?.asObject ?? [:]
        if let span {
            bySurface[surface.rawValue] = .string(span.stored)
        } else {
            bySurface.removeValue(forKey: surface.rawValue)
        }
        if bySurface.isEmpty {
            section.removeValue(forKey: Self.sizeKey)
        } else {
            section[Self.sizeKey] = .object(bySurface)
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
    /// rather than factoring it out — `settingMembership` repeats it once per level, three times
    /// over. This file factors it instead because both settings here (`settingSubsectionSpan` and
    /// `settingSubsectionMode`) walk the *exact same* two-level subtree — kind-section, then
    /// `subsections` root — so the duplication would be between them as well as within each, not
    /// because no inlined precedent exists.
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
