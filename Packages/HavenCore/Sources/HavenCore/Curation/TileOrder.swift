import Foundation

/// What order a room's tiles are in.
///
/// Three rules, all pure, because ordering is where a home's own history shows up: Home Assistant
/// gains and loses entities long after somebody arranged a room, and what happens then is the whole
/// question.
public enum TileOrder {
    /// The order a room is in before anybody rearranges it.
    ///
    /// Climate, then everything miscellaneous, then media, then cameras — the banding the room's four
    /// separate grids used to encode structurally, kept when they became one grid so that adopting
    /// the grid moved nothing on its own.
    ///
    /// Climate leads because a room's temperature is what a glance is usually for. Cameras trail
    /// because four feeds at the top of every room would make the dashboard a security console.
    public static func defaultOrder(_ ids: [String]) -> [String] {
        func matching(_ predicate: (Domain) -> Bool) -> [String] {
            ids.filter { predicate(Domain.of($0)) }
        }
        let climate = matching { $0 == .climate }
        let media = matching { $0 == .mediaPlayer }
        let cameras = matching { $0 == .camera }
        let rest = matching { $0 != .climate && $0 != .mediaPlayer && $0 != .camera }
        return climate + rest + media + cameras
    }

    /// A stored order reconciled against what the room actually has.
    ///
    /// 1. Stored ids still present, in stored order.
    /// 2. Then present ids the stored order does not mention, in `defaultOrder`, appended.
    /// 3. Stored ids no longer present are dropped.
    ///
    /// **Rule 2 is the one that matters.** A device added in Home Assistant a month after somebody
    /// arranged this room has to turn up somewhere obvious. Dropping it would lose a device the user
    /// owns; putting it first would rearrange a room nobody touched. The end is the only answer that
    /// is both visible and inert.
    ///
    /// Rule 3 costs nothing and stops the stored list filling up with the ghosts of removed devices.
    public static func resolve(stored: [String], present: [String]) -> [String] {
        let presentSet = Set(present)
        let kept = stored.filter(presentSet.contains)
        let keptSet = Set(kept)
        let newcomers = defaultOrder(present.filter { !keptSet.contains($0) })
        return kept + newcomers
    }

    /// `order` with `id` moved to sit immediately before `target` — or last, when `target` is nil.
    ///
    /// **Here rather than in the drop handler, because this is where the off-by-one lives.** Removing
    /// the dragged id shifts everything after it down one, so an implementation that reads the
    /// target's index *before* removing lands one place early whenever a tile is dragged forwards
    /// past its own position. That is the single most common drag a user makes and the easiest to get
    /// subtly wrong in a view.
    ///
    /// Dropping something onto itself is a no-op rather than a removal or a duplication: a lift that
    /// goes nowhere is a gesture people make constantly.
    public static func moving(_ id: String, before target: String?, in order: [String]) -> [String] {
        guard order.contains(id) else { return order }
        if let target {
            guard target != id, order.contains(target) else { return order }
        }
        var out = order.filter { $0 != id }
        guard let target, let index = out.firstIndex(of: target) else {
            out.append(id)
            return out
        }
        out.insert(id, at: index)
        return out
    }
}
