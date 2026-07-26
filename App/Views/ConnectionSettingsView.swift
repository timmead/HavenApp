import SwiftUI
import CoreLocation
import HavenCore

/// Where the optional "connect faster at home" upgrade is offered — **and the only place a
/// location permission prompt can originate.**
///
/// The framing is deliberate and is a product decision, not copy. This is an accelerator the user
/// opts into after the app already works, described in terms of what it does for them, with the
/// cost of declining stated plainly ("Haven still works — it just tries your local address first
/// and falls back"). Asking during onboarding instead would trade a first-run permission prompt —
/// in a privacy-led, local-first app — for about two seconds, which is a bad trade and reads worse.
struct ConnectionSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    switch app.homeNetwork.authorization {
                    case .notDetermined:
                        Button {
                            // The single call site of `requestPermission()` in the whole app.
                            app.homeNetwork.requestPermission()
                        } label: {
                            Label("Connect faster at home", systemImage: "wifi")
                        }
                    case .authorizedWhenInUse, .authorizedAlways:
                        Label {
                            Text(app.homeNetwork.homeSSID.map { "Home network: \($0)" }
                                 ?? "Home network not learned yet")
                        } icon: {
                            Image(systemName: "wifi")
                        }
                        .foregroundStyle(.primary)
                    default:
                        Label("Wi-Fi network access is off", systemImage: "wifi.slash")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Home Wi-Fi")
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Every branch says the same underlying thing — this is optional and nothing breaks without
    /// it — because that is true, and because a user who reads "denied" as "something is wrong"
    /// will grant a permission they didn't want to.
    private var footer: String {
        switch app.homeNetwork.authorization {
        case .notDetermined:
            return """
            Haven can recognise your home Wi-Fi and go straight to your local address instead of \
            trying it and waiting. iOS needs location access to tell Haven which Wi-Fi network \
            you're on; your location is never read, stored or sent anywhere.

            Haven works exactly the same without this — it just tries your local address first and \
            falls back to your remote one, which takes a couple of seconds longer when you're out.
            """
        case .authorizedWhenInUse, .authorizedAlways:
            return app.homeNetwork.homeSSID == nil
                ? "Haven will remember your home Wi-Fi the next time it connects over your local network."
                : "Haven goes straight to your local address on this network, and straight to your remote one everywhere else."
        default:
            return """
            Haven can't tell which Wi-Fi network you're on, so it tries your local address first \
            and falls back to your remote one. Everything works; connecting away from home just \
            takes a couple of seconds longer. You can turn location access on for Haven in the \
            Settings app if you'd like it to be instant.
            """
        }
    }
}
