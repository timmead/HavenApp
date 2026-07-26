import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    /// Connection settings, reachable from **every** phase — not just `.ready` (review finding I-2).
    /// It used to be presented only from `DashboardView`'s overflow menu, and `RootView` renders
    /// `DashboardView` only when `phase == .ready`. So a self-hosted user stranded away from home
    /// sat in `.retrying` indefinitely with no way to open the one screen holding the custom
    /// remote URL field — the exact user that feature exists for, locked out of the fix at the only
    /// moment they need it. `DashboardView` keeps its own entry point; this is the second one.
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
        case .retrying(let attempt):
            VStack(spacing: 16) {
                ProgressView("Connection lost — retrying… (attempt \(attempt))")
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
