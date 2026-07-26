import Foundation
import CoreLocation
import NetworkExtension
import HavenCore

/// Layer 1 of the home-detection stack: "is the phone on the Wi-Fi network we last reached Home
/// Assistant locally over?" It is the only layer that can actually answer that, and it is
/// **optional, opt-in, and never on the critical path**.
///
/// ## The permission posture — this is a product decision, not an implementation detail
///
/// Reading the current SSID (`NEHotspotNetwork.fetchCurrent`) requires Location Services
/// authorization. That prompt is **never shown during onboarding.** A location prompt in the first
/// sixty seconds of a local-first, privacy-led home app costs more trust than the ~2 seconds of
/// latency it saves, and a user who declines it — the expected, reasonable choice — must end up
/// with an app that is *fully correct*, merely one probe slower. So:
///
/// - `requestPermission()` is reachable **only** from the settings surface
///   (`ConnectionSettingsView`), framed as "connect faster at home". Nothing in `AppModel.init`,
///   `restoreIfPossible()` or `connect()` may call it, and merely *constructing* a
///   `CLLocationManager` does not prompt — only `requestWhenInUseAuthorization()` does.
/// - `currentSSID()` returns `nil` whenever authorization is absent. `nil` flows into
///   `ConnectionPreference.homeSSIDMatch` as "unknown", which is defined to behave exactly like the
///   layer not existing. **`nil` must never be read as "not home".**
/// - The home SSID is **captured automatically on a successful local connection** — we know we were
///   home, because the peer's address said so — so the user never types it.
///
/// ## Degradation
///
/// Every reason this can fail — permission not granted, permission denied, the *Access WiFi
/// Information* entitlement not provisioned on the build, a device with no Wi-Fi — produces the
/// same result: SSID unknown, layers 2–3 do the work. There is no error state, because there is no
/// error: this layer is an accelerator.
@MainActor @Observable
final class HomeNetwork {
    /// Where the home SSID is remembered. Not a secret (unlike anything in `KeychainTokenStore`),
    /// and cleared on sign-out alongside the discovered URLs — it describes *this* instance's
    /// network, and would be actively misleading if it survived into a different one.
    static let homeSSIDKey = "havenapp.homeSSID"

    /// Current Location Services authorization. Observed so the settings surface reflects a change
    /// made in the system Settings app without needing to be reopened.
    private(set) var authorization: CLAuthorizationStatus

    private let manager = CLLocationManager()
    private var authorizationObserver: LocationAuthorizationObserver?

    init() {
        authorization = manager.authorizationStatus
        let observer = LocationAuthorizationObserver { [weak self] status in
            Task { @MainActor in self?.authorization = status }
        }
        authorizationObserver = observer
        manager.delegate = observer
    }

    /// Whether the SSID can be read at all right now. `false` is an entirely ordinary state.
    var canReadSSID: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    /// `true` only before the user has been asked — the settings surface uses this to decide
    /// between offering the prompt and pointing at the Settings app (iOS only ever prompts once).
    var canRequestPermission: Bool { authorization == .notDetermined }

    /// The SSID the app will treat as "home", or `nil` if no local connection has been made yet.
    var homeSSID: String? {
        UserDefaults.standard.string(forKey: Self.homeSSIDKey)
    }

    /// **The only place that may trigger a system permission prompt, and it must stay that way.**
    /// Called from `ConnectionSettingsView` in response to a deliberate tap, never from a connect
    /// path. When-in-use is sufficient — we only read the SSID while the user is looking at the
    /// app — and "Always" would be a far bigger ask for no gain.
    func requestPermission() {
        guard canRequestPermission else { return }
        manager.requestWhenInUseAuthorization()
    }

    /// The SSID of the Wi-Fi network currently joined, or `nil` when it cannot be read — no
    /// authorization, no entitlement on this build, not on Wi-Fi, or no network at all. Every one
    /// of those is "unknown", not "not home".
    func currentSSID() async -> String? {
        guard canReadSSID else { return nil }
        return await withCheckedContinuation { continuation in
            // Only the `String` is carried out of the callback; `NEHotspotNetwork` itself stays put.
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }

    /// Records the current network as "home". Called by `AppModel` after a connection whose
    /// **observed peer address** was private — i.e. we have positive evidence we were on the home
    /// LAN, from the socket rather than from anything self-reported.
    ///
    /// A no-op when the SSID can't be read, which is why granting permission later still works:
    /// the next local connection captures it. Overwrites rather than appends — a single home
    /// network, matching the design's deferral of BSSID/multi-AP handling.
    func rememberCurrentNetworkAsHome() async {
        guard let ssid = await currentSSID(), !ssid.isEmpty else { return }
        guard ssid != homeSSID else { return }
        UserDefaults.standard.set(ssid, forKey: Self.homeSSIDKey)
        havenLog.info("captured the home Wi-Fi network from a connection whose peer address was on the local network")
    }

    /// Cleared on sign-out with everything else that describes how to reach the old instance.
    func forgetHomeNetwork() {
        UserDefaults.standard.removeObject(forKey: Self.homeSSIDKey)
    }
}

/// `CLLocationManager` reports authorization changes only through a delegate. Kept as a separate
/// non-isolated object so `HomeNetwork` can stay `@MainActor` without forcing a nonisolated
/// conformance onto it.
private final class LocationAuthorizationObserver: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let onChange: @Sendable (CLAuthorizationStatus) -> Void
    init(onChange: @escaping @Sendable (CLAuthorizationStatus) -> Void) { self.onChange = onChange }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onChange(manager.authorizationStatus)
    }
}
