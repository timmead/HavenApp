import SwiftUI
import HavenCore

/// What is on screen, as opposed to what Home Assistant said.
///
/// This held one property — the entity id whose modal is open — and it lived on `HomeStore`, beside
/// the entity states, the registry and the history caches. The tell was `reset()`: tearing down a
/// *session* had to remember to close a *sheet*, which is two unrelated things in one function
/// because they happened to share an object.
///
/// **Owned by `DashboardView` as `@State`, deliberately, rather than by `AppModel`.** That is what
/// makes the coupling disappear instead of merely moving: the modal can only be opened from a tile,
/// every tile lives inside `DashboardView`, and `RootView` renders `DashboardView` only while
/// `phase == .ready`. So sign-out, reauthentication and a mid-session reconnect all tear this down
/// on their way past — the stale-modal problem `HomeStore.reset` was solving is structurally
/// impossible rather than solved by remembering to nil something.
///
/// Configuration mode lives here for the same reason, and it is the stronger case: a half-edited
/// dashboard must not survive a sign-out and reappear behind someone else's login.
@MainActor @Observable
final class Navigation {
    /// What is presented above the dashboard.
    ///
    /// **One value, not one flag per sheet.** Two independent booleans can both be true, and SwiftUI
    /// presents whichever it notices first while the other silently does nothing — which is the
    /// shape of every "the wrong sheet opened" bug.
    enum Presentation: Equatable {
        /// The device's controls — the ordinary tap or long-press outside configuration mode.
        case control(entityId: String)
        /// The device's configuration — what a tap does *in* configuration mode.
        ///
        /// Carries the surface it was opened from, because "remove" means "off *this* surface" and
        /// this sheet is reached from both the dashboard and room detail.
        case tileConfig(entityId: String, surface: HavenSurface)
        /// A room's configuration, from its title.
        case roomConfig(areaId: String)
        /// The picker behind a surface's `+` — what this room has that the surface isn't showing.
        case addTile(areaId: String, surface: HavenSurface)
    }

    var presented: Presentation?

    /// Whether the dashboard is being configured. Written by the toolbar, read by every tile.
    var isConfiguring = false

    /// What a tile's activation means, resolved in one place: its controls normally, its
    /// configuration while configuring.
    ///
    /// Tiles call this instead of writing `presented` directly, so a tile added later cannot forget
    /// the mode and stay live during configuration — the failure would be a tap that turns a light
    /// on while the user is trying to rename it.
    func open(_ entityId: String, on surface: HavenSurface) {
        presented = isConfiguring
            ? .tileConfig(entityId: entityId, surface: surface)
            : .control(entityId: entityId)
    }
}

extension Navigation.Presentation: Identifiable {
    /// Identity includes the case, not just the entity id: opening a tile's *configuration* while
    /// its *controls* are open must be a different sheet, not the same one relabelled.
    var id: String {
        switch self {
        case .control(let entityId): return "control:\(entityId)"
        case .tileConfig(let entityId, let surface): return "tileConfig:\(surface.rawValue):\(entityId)"
        case .roomConfig(let areaId): return "roomConfig:\(areaId)"
        case .addTile(let areaId, let surface): return "addTile:\(surface.rawValue):\(areaId)"
        }
    }
}
