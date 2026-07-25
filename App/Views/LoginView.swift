import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model
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
        }.padding()
    }
}
