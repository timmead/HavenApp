import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model

    /// Owned by `RootView`, which presents the sheet — see its documentation. The login surface is
    /// also `phase == .error`, where a terminal failure lands (an ATS-blocked token refresh, for
    /// one), so connection settings have to be reachable from here too and not only from a
    /// dashboard the user may never have got to.
    @Binding var showingConnectionSettings: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 16) {
            Text("Connect to Home Assistant").font(.title2.bold())
            TextField("http://homeassistant.local:8123", text: $model.serverURLText)
                .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never)
                .autocorrectionDisabled().keyboardType(.URL)
            Button("Sign in") { Task { await model.signIn() } }
                .buttonStyle(.borderedProminent)
            if case let .error(msg) = model.phase { Text(msg).font(.footnote).foregroundStyle(.red) }
            Button("Connection settings") { showingConnectionSettings = true }
                .font(.footnote)
        }.padding()
    }
}
