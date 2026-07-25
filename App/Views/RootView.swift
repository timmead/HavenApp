import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        switch model.phase {
        case .loggedOut, .error: LoginView()
        case .connecting: ProgressView("Connecting…")
        case .ready: DashboardView().environment(model.store)
        }
    }
}
