import Foundation

/// Which floor the dashboard's horizontal pager should be showing.
public enum FloorPaging {
    /// The selection to hold after the floor list changes.
    ///
    /// The pager's selection is a floor id owned by the view, but the floor list is rebuilt from
    /// scratch on every registry reload, and the floor a user is standing on can vanish across one:
    /// an area gets moved to another floor, or the last unfiled entity finally gets an area and the
    /// synthetic "Home" floor disappears with it. A selection naming a floor that no longer exists
    /// gives `.scrollPosition(id:)` nothing to scroll to — a blank dashboard with a bar full of
    /// floors, none of them selected — so the id is re-derived here rather than left to rot.
    ///
    /// Falls back to the first floor, which after `RegistryResolver` is "Home" whenever there is
    /// one. `nil` only for a home with no floors at all, i.e. before the first load.
    public static func selection(current: String?, floors: [ResolvedFloor]) -> String? {
        if let current, floors.contains(where: { $0.id == current }) { return current }
        return floors.first?.id
    }
}
