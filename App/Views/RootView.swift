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

    /// How long a connection may be in progress before this view says anything about it.
    ///
    /// A healthy connect completes in well under a second (measured: ~730ms to a bootstrapped
    /// dashboard on a local network), so without a quiet period the connecting spinner appears and
    /// vanishes in a blink on every launch — motion that reads as a glitch and tells the user
    /// nothing they can use. Three seconds is comfortably past a normal connect and comfortably
    /// short of the point where silence would itself look broken.
    ///
    /// It is also `ReconnectPolicy`'s first backoff, which is the useful coincidence: if the first
    /// round fails, this screen arrives at roughly the moment the second round begins, so its
    /// appearance lines up with something actually having gone wrong.
    private static let quietPeriod: Duration = .seconds(3)

    /// Whether a connection has been in progress long enough to be worth mentioning.
    @State private var connectingIsWorthMentioning = false

    var body: some View {
        content
            .sheet(isPresented: $showingConnectionSettings) { ConnectionSettingsView() }
            // Keyed on *whether* a connection is in progress, not on the phase — so the timer runs
            // from when connecting began and keeps running across `.connecting` → `.retrying`.
            // Restarting it per phase would mean a connection that failed a round and moved on had
            // its quiet period begin again, and the screen would never appear at all.
            .task(id: model.phase.isConnectionInProgress) {
                guard model.phase.isConnectionInProgress else {
                    connectingIsWorthMentioning = false
                    return
                }
                try? await Task.sleep(for: Self.quietPeriod)
                guard !Task.isCancelled else { return }
                connectingIsWorthMentioning = true
            }
    }

    /// The screen for a connection that has been going long enough to owe the user an explanation
    /// and a way out.
    ///
    /// The message is `Phase.connectionProgressMessage`'s — this view does not decide what to say,
    /// only when to say it, which is the split that keeps the wording testable.
    private func trouble(_ message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView(message)
            // Offered ahead of "Change server", which signs out and discards the session: this is
            // the non-destructive way out of a retry loop, and for someone whose only working
            // address is one Haven doesn't know yet, it is the one that fixes it.
            Button("Connection settings") { showingConnectionSettings = true }
            Button("Change server") { Task { await model.signOut() } }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loggedOut, .error:
            LoginView(showingConnectionSettings: $showingConnectionSettings)
        case .launching, .connecting, .retrying:
            // **The connecting screen shows immediately; only the *trouble* screen is delayed.**
            //
            // An earlier version held everything back for the quiet period and rendered a blank
            // screen in the meantime. That removed the flashing spinner but replaced it with a gap,
            // and a gap is its own kind of wrong on a cold launch. `ConnectingView` is calm enough
            // to be the launch experience, so there is nothing to hold back — what needs holding
            // back is the attempt count and the two escape hatches, which say "something is wrong"
            // and should not appear while nothing is.
            if let message = model.phase.connectionProgressMessage, connectingIsWorthMentioning {
                trouble(message)
            } else {
                ConnectingView()
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
