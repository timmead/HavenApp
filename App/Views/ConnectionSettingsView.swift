import SwiftUI
import CoreLocation
import UIKit
import HavenCore

/// Where the optional "connect faster at home" upgrade is offered — **and the only place a
/// location permission prompt can originate.**
///
/// The framing is deliberate and is a product decision, not copy. This is an accelerator the user
/// opts into after the app already works, described in terms of what it does for them, with the
/// cost of declining stated plainly ("Haven still works — it just tries your local address first
/// and falls back"). Asking during onboarding instead would trade a first-run permission prompt —
/// in a privacy-led, local-first app — for about two seconds, which is a bad trade and reads worse.
///
/// ## Why this screen also lets the user set the home network directly
///
/// Auto-capture (`HomeNetwork.rememberCurrentNetworkAsHome`, fired from `AppModel` after a
/// connection classified `.local`) covers the common case, but it cannot be the *only* path: a home
/// whose Home Assistant answers on a globally-routable IPv6 address is never classified `.local` by
/// address alone (see `ConnectionClass.observed`), so auto-capture never runs there. "Use this Wi-Fi
/// network as my home network" is the explicit way to teach the app that fact instead — the same
/// thing the Home Assistant companion app asks the user to configure directly, rather than trying to
/// infer it.
struct ConnectionSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// The SSID of the network currently joined, independent of whether it matches `homeSSID`.
    /// Fetched fresh whenever authorization changes (including a grant made while this screen is
    /// open, via the system Settings app) rather than once on appear — a stale `nil` here would
    /// read as "not on Wi-Fi" even after the user just granted permission.
    @State private var currentSSID: String?

    /// The custom remote URL being edited. Seeded from `app.customRemoteURL` when the screen
    /// appears and thereafter owned by the text field — the model is only updated when the user
    /// actually saves, so an abandoned half-typed address changes nothing.
    @State private var customRemoteText = ""

    /// The last save attempt's rejection, or `nil`. The text comes from
    /// `CustomRemoteURLError.message` in HavenCore and is rendered verbatim — same arrangement as
    /// `RemoteAccessOfferModel.failureMessage`, and for the same reason: "`http://` is rejected with
    /// an actionable explanation" is a behaviour, and no test drives this screen's text fields.
    @State private var customRemoteError: String?

    var body: some View {
        NavigationStack {
            List {
                // Shown whenever there's an offer to make *or* something to say about the last
                // attempt — the latter matters on its own: a transport blip right after
                // `cloud/remote/connect` reclassifies as `.indeterminate`, not `.remoteDisabled`,
                // so `offer` can go `nil` in the same moment `failureMessage` is set. Gating this
                // section on `offer` alone would make that failure message invisible — the exact
                // dead end a "failed enable surfaces an actionable message" requirement exists to
                // prevent.
                if app.remoteAccessOffer.offer != nil || app.remoteAccessOffer.failureMessage != nil {
                    remoteAccessSection(app.remoteAccessOffer.offer)
                }
                customRemoteURLSection
                Section {
                    if !HomeNetwork.isSSIDDetectionAvailable {
                        // Say what's true rather than letting the permission switch below run: with
                        // no entitlement `currentSSID()` is permanently nil, so `authorizedRows`
                        // would render "Not on Wi-Fi" to someone plainly on Wi-Fi, and
                        // `.notDetermined` would offer a Location prompt that changes nothing.
                        Label("Wi-Fi network detection isn't available in this build",
                              systemImage: "wifi.slash")
                            .foregroundStyle(.secondary)
                    } else {
                    switch app.homeNetwork.authorization {
                    case .notDetermined:
                        Button {
                            // The single call site of `requestPermission()` in the whole app.
                            app.homeNetwork.requestPermission()
                        } label: {
                            Label("Connect faster at home", systemImage: "wifi")
                        }
                    case .authorizedWhenInUse, .authorizedAlways:
                        authorizedRows
                    default:
                        Label("Wi-Fi network access is off", systemImage: "wifi.slash")
                            .foregroundStyle(.secondary)
                        // Not a dead end: iOS only ever shows the system prompt once, so the only
                        // way back from "denied" is the Settings app. Offer it rather than making
                        // the user go find it themselves.
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        } label: {
                            Label("Open Settings", systemImage: "gear")
                        }
                    }
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
            // Re-fetched on every authorization change, not just once at appear — see the
            // property's doc comment.
            .task(id: app.homeNetwork.authorization) {
                currentSSID = await app.homeNetwork.currentSSID()
            }
            // Seeded once per appearance rather than bound to the model: mid-edit text is not a
            // saved setting, and rewriting the field from `app.customRemoteURL` on every model
            // change would fight the keyboard.
            .onAppear { customRemoteText = app.customRemoteURL?.absoluteString ?? "" }
            // Mirrors `OnboardingView`'s confirmation alert exactly — same confirmation type
            // (`HavenOnboardingConfirmation`), same gating (`pendingConfirmation != nil`), because
            // this is the same confirmation machinery, not a second one.
            .alert(
                app.remoteAccessOffer.pendingConfirmation?.title ?? "",
                isPresented: Binding(
                    get: { app.remoteAccessOffer.pendingConfirmation != nil },
                    set: { if !$0 { app.remoteAccessOffer.cancelConfirmation() } }
                ),
                presenting: app.remoteAccessOffer.pendingConfirmation
            ) { confirmation in
                Button(confirmation.confirmLabel) {
                    Task { await app.remoteAccessOffer.confirmPendingMutation() }
                }
                Button("Cancel", role: .cancel) { app.remoteAccessOffer.cancelConfirmation() }
            } message: { confirmation in
                Text(confirmation.message)
            }
        }
    }

    /// Task 3's one-tap fix. `offer` can be `nil` here even though the section is showing — see the
    /// call site: a failed attempt's re-probe can reclassify away from `.remoteDisabled` (e.g. to
    /// `.indeterminate` on a transport blip), clearing the offer in the very same moment
    /// `failureMessage` is set to explain that attempt. The message must still render then, which
    /// is why this section, and not just its button, is conditional on the offer.
    @ViewBuilder
    private func remoteAccessSection(_ offer: NabuCasaRemoteAccessOffer?) -> some View {
        Section {
            if let offer {
                Text(offer.explanation)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            if let failure = app.remoteAccessOffer.failureMessage {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundStyle(HavenColor.warning)
            }
            // No button at all when there's no current offer, or when `canEnable` is false — see
            // `NabuCasaRemoteAccessOffer`'s documentation: there is no confirmation to reach in the
            // latter case, and a button with nothing behind it would be a dead end rather than an
            // explanation.
            if let offer, offer.canEnable {
                Button {
                    app.remoteAccessOffer.requestConfirmation()
                } label: {
                    if app.remoteAccessOffer.isBusy {
                        ProgressView()
                    } else {
                        Label("Turn on remote access", systemImage: "network")
                    }
                }
                .disabled(app.remoteAccessOffer.isBusy)
            }
        } header: {
            Text("Remote access")
        }
    }

    /// Task 6: the second supported remote path, for people who reach their Home Assistant through
    /// Tailscale or their own reverse proxy rather than Nabu Casa.
    ///
    /// Always shown, including for a Nabu Casa subscriber — the two are not alternatives. Someone
    /// can legitimately run both, and the whole reason this address has a storage slot of its own is
    /// so that having Nabu Casa doesn't silently delete it (see `CustomRemoteURLStore`). The footer
    /// says which is tried first so that ordering isn't a surprise.
    ///
    /// No validation happens here. The button hands the raw text to `AppModel`, which forwards it to
    /// HavenCore; what comes back is either a URL or a message to display.
    @ViewBuilder
    private var customRemoteURLSection: some View {
        Section {
            // Design §3's outcomes 3 and 4, which had no surface at all before (review finding
            // I-2): the self-hosted user, the signed-out account, the lapsed subscription and the
            // "we couldn't tell" case each get their own sentence, and each says the custom address
            // below is the way through. The copy — including the fact that `.cloudNotLoaded` must
            // not read as "you need Nabu Casa" — is `NabuCasaRemoteAccess.customRemoteURLGuidance`
            // in HavenCore, with tests. `nil` for `.remoteAvailable`/`.remoteDisabled`, which have
            // their own surfaces.
            if let guidance = app.remoteAccess?.customRemoteURLGuidance {
                Text(guidance)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            TextField("https://ha.example.com", text: $customRemoteText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .onSubmit { saveCustomRemoteURL() }

            if let customRemoteError {
                Label(customRemoteError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundStyle(HavenColor.warning)
            }

            Button {
                saveCustomRemoteURL()
            } label: {
                Label("Save remote address", systemImage: "checkmark.circle")
            }
            // Nothing to save when the field already matches what's stored — including the common
            // "opened settings, changed nothing" case.
            .disabled(customRemoteText == (app.customRemoteURL?.absoluteString ?? ""))

            if app.customRemoteURL != nil {
                Button(role: .destructive) {
                    app.clearCustomRemoteURL()
                    customRemoteText = ""
                    customRemoteError = nil
                } label: {
                    Label("Remove remote address", systemImage: "trash")
                }
            }
        } header: {
            Text("Your own remote address")
        } footer: {
            Text(customRemoteFooter)
        }
    }

    /// Stated plainly rather than implied, because both facts surprise people: the address must be
    /// HTTPS (and Haven will say so rather than quietly changing it), and it is tried *after* Nabu
    /// Casa when both exist — but it is still tried, which is the point.
    private var customRemoteFooter: String {
        // Only claimed when `cloud/status` actually reported a usable Nabu Casa address — every
        // other outcome (no subscription, cloud component absent, indeterminate) means this address
        // is the only remote path there is, and saying otherwise would be noise at best.
        var hasNabuCasa = false
        if case .remoteAvailable = app.remoteAccess { hasNabuCasa = true }
        let ordering = hasNabuCasa
            ? " Your Home Assistant also has Nabu Casa remote access; Haven tries that first and this second."
            : ""
        // The lead-in is dropped when the guidance above the field already said it — otherwise a
        // `.cloudNotLoaded` user reads the same sentence twice on one screen.
        let leadIn = app.remoteAccess?.customRemoteURLGuidance == nil
            ? "If you reach Home Assistant from outside your home some other way — Tailscale, or your own reverse proxy — enter that address here and Haven will use it when you're away. "
            : ""
        return """
        \(leadIn)It must be an https:// address, because it travels over the internet.\(ordering) \
        Changes take effect the next time Haven connects.
        """
    }

    private func saveCustomRemoteURL() {
        switch app.saveCustomRemoteURL(customRemoteText) {
        case .success(let url):
            // Show what was actually stored — `https://` filled in for a scheme-less entry, trailing
            // whitespace gone — so the field never disagrees with the address Haven will dial.
            customRemoteText = url.absoluteString
            customRemoteError = nil
        case .failure(let error):
            customRemoteError = error.message
        }
    }

    @ViewBuilder
    private var authorizedRows: some View {
        Label {
            Text(currentSSID.map { "Current network: \($0)" } ?? "Not on Wi-Fi")
        } icon: {
            Image(systemName: "wifi")
        }
        .foregroundStyle(.primary)

        Label {
            Text(app.homeNetwork.homeSSID.map { "Home network: \($0)" } ?? "Home network not set")
        } icon: {
            Image(systemName: "house")
        }
        .foregroundStyle(.primary)

        if let currentSSID, currentSSID != app.homeNetwork.homeSSID {
            Button {
                Task { await app.homeNetwork.rememberCurrentNetworkAsHome() }
            } label: {
                Label("Use this Wi-Fi network as my home network", systemImage: "house.fill")
            }
        }

        if app.homeNetwork.homeSSID != nil {
            Button(role: .destructive) {
                app.homeNetwork.forgetHomeNetwork()
            } label: {
                Label("Forget home network", systemImage: "trash")
            }
        }
    }

    /// Every branch says the same underlying thing — this is optional and nothing breaks without
    /// it — because that is true, and because a user who reads "denied" as "something is wrong"
    /// will grant a permission they didn't want to.
    ///
    /// The authorized case is split on `currentSSID` rather than assumed readable: authorization
    /// alone doesn't guarantee `currentSSID()` returns a value (not currently on Wi-Fi, or the
    /// *Access WiFi Information* entitlement isn't provisioned on this build — see `HomeNetwork`).
    /// `authorizedRows` doesn't show the "use this network" button when `currentSSID` is `nil`, so
    /// this text must not claim it's there either — a footer promising a button the screen doesn't
    /// show is exactly the dead end this screen exists to avoid.
    private var footer: String {
        guard HomeNetwork.isSSIDDetectionAvailable else {
            return """
            Recognising your home Wi-Fi needs a capability that isn't enabled in this build, so \
            Haven can't tell which network you're on.

            Everything works without it — Haven tries your local address first and falls back to \
            your remote one, which takes a couple of seconds longer when you're away from home.
            """
        }
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
            if currentSSID == nil {
                return app.homeNetwork.homeSSID == nil
                    ? "Haven can't read the current Wi-Fi network right now — join a Wi-Fi network to set it as home, or Haven will remember it automatically the next time it connects over your local network."
                    : "Haven can't read the current Wi-Fi network right now, but it will still go straight to your local address on your home network and your remote one everywhere else."
            }
            return app.homeNetwork.homeSSID == nil
                ? "Haven will remember your home Wi-Fi the next time it connects over your local network, or you can set the network above as home right now."
                : "Haven goes straight to your local address on this network, and straight to your remote one everywhere else. Setting a new home network here takes effect the next time Haven connects, not immediately."
        default:
            return """
            Haven can't tell which Wi-Fi network you're on, so it tries your local address first \
            and falls back to your remote one. Everything works; connecting away from home just \
            takes a couple of seconds longer. Turn location access on for Haven in Settings if \
            you'd like it to be instant.
            """
        }
    }
}
