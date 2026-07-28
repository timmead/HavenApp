import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    /// Connection settings, reachable from **every** phase — not just `.ready` (review finding I-2).
    /// It used to be presented only from `DashboardView`'s overflow menu, and `RootView` renders
    /// `DashboardView` only when `phase == .ready`. So a self-hosted user stranded away from home
    /// sat in `.retrying` indefinitely with no way to open the one screen holding the custom
    /// remote URL field — the exact user that feature exists for, locked out of the fix at the only
    /// moment they need it. `DashboardView` keeps its own entry point; this is the second one.
    ///
    /// **Nothing in `Tests/HavenAppTests` covers this, and the reason is worth recording so the next
    /// person doesn't spend the afternoon rediscovering it.** The obvious test — host `RootView` in
    /// a `UIWindow` and look for a "Connection settings" control — cannot work under
    /// `xcodebuild test`. SwiftUI draws its text rather than vending `UILabel`s, so the only public
    /// way to read it back is the accessibility tree, and SwiftUI builds no accessibility nodes
    /// unless an assistive technology is attached to the process. That happens to be true on a
    /// simulator sitting in the foreground of Simulator.app, and is false on a headless device
    /// booted by `xcodebuild` — so the probe passed where it was written and returned an empty set
    /// everywhere else (window attached, scene foreground-active, view in the window, zero labels).
    ///
    /// A `phaseOffersConnectionSettings` predicate was deliberately *not* written in its place:
    /// a second copy of this decision that a change to the `switch` below could silently
    /// contradict is how the URL-adoption fix shipped with 107 green tests over a helper. If this
    /// is to be covered, the way is to make the control and the rule one production type both entry
    /// points use, so there is one expression to test rather than a duplicate to keep in step.
    @State private var showingConnectionSettings = false

    var body: some View {
        content
            .sheet(isPresented: $showingConnectionSettings) { ConnectionSettingsView() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loggedOut, .error:
            LoginView(showingConnectionSettings: $showingConnectionSettings)
        case .connecting: ProgressView("Connecting…")
        case .retrying(let attempt, let isReconnect):
            VStack(spacing: 16) {
                // Two different sentences because they describe two different situations, and the
                // wrong one is actively misleading. "Connection lost" to someone who has just
                // opened the app asserts that something broke — it reads as a fault in their Home
                // Assistant or their network, when the ordinary cause is a first connect that
                // simply has not landed yet. The first-connect copy says what is true and nothing
                // more. Which of the two applies is `Phase.retrying`'s to say, not this view's.
                ProgressView(isReconnect
                             ? "Connection lost — retrying… (attempt \(attempt))"
                             : "Connecting to Home Assistant… (attempt \(attempt))")
                // Offered ahead of "Change server", which signs out and discards the session: this
                // is the non-destructive way out of a retry loop, and for someone whose only
                // working address is one Haven doesn't know yet, it is the one that fixes it.
                Button("Connection settings") { showingConnectionSettings = true }
                Button("Change server") { Task { await model.signOut() } }
            }
        case .ready:
            // Onboarding rides *over* the dashboard rather than replacing it: the rest of the app
            // works without the `havenapp` integration, so blocking a working home behind a setup
            // screen would be a regression. Whether there's anything to show is
            // `HavenOnboardingFlow.needsGuidance`'s call, made when the probe lands — never a
            // condition assembled here.
            DashboardView()
                .environment(model.store)
                .sheet(isPresented: Binding(
                    get: { model.onboarding.isPresented },
                    set: { model.onboarding.isPresented = $0 }
                )) {
                    OnboardingView(model: model.onboarding)
                }
        }
    }
}
