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
                Button("Change server") { model.signOut() }
            }
        case .ready: DashboardView().environment(model.store)
        }
    }
}
