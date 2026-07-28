import SwiftUI

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
@MainActor @Observable
final class Navigation {
    /// The entity whose modal is open, or `nil` for none. Written by the tiles (tap or long-press,
    /// depending on whether the tile has its own primary action) and read by `DashboardView`'s
    /// sheet.
    var presentedEntityId: String?
}
