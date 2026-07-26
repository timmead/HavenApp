import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        switch model.phase {
        case .loggedOut, .error: LoginView()
        case .connecting: ProgressView("Connecting…")
        case .retrying(let attempt):
            VStack(spacing: 16) {
                ProgressView("Connection lost — retrying… (attempt \(attempt))")
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
