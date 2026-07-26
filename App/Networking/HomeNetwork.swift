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
///   home, because the peer's address said so — so the user never types it in the common case.
/// - It can also be **set explicitly from `ConnectionSettingsView`** ("Use this Wi-Fi network as my
///   home network"). This is the only bootstrap path for a home whose Home Assistant answers on a
///   globally-routable IPv6 address (SLAAC GUA): `ConnectionClass.observed` never classifies that
///   connection `.local` from the address alone, so auto-capture (which is gated on exactly that)
///   never fires, and the user would otherwise have no way to teach the app "this network is home".
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

    /// The SSID the app will treat as "home", or `nil` if none has been captured or set yet.
    ///
    /// A **stored**, `@Observable`-tracked property, not a computed read of `UserDefaults` — the
    /// settings screen is now both writer (the explicit "use this network" action) and reader (it
    /// displays this value) of the same instance, and `@Observable` only tracks stored properties.
    /// A computed re-read would leave the button appearing to do nothing until the view happened to
    /// re-render for an unrelated reason. Seeded from `UserDefaults` at init and kept in sync with it
    /// on every write below, so it still survives relaunches exactly as before.
    private(set) var homeSSID: String?

    private let manager = CLLocationManager()
    private var authorizationObserver: LocationAuthorizationObserver?

    init() {
        authorization = manager.authorizationStatus
        homeSSID = UserDefaults.standard.string(forKey: Self.homeSSIDKey)
        let observer = LocationAuthorizationObserver { [weak self] status in
            Task { @MainActor in self?.authorization = status }
        }
        authorizationObserver = observer
        manager.delegate = observer
    }

    /// Whether this *build* can read an SSID at all, regardless of permission.
    ///
    /// Reading the SSID needs the restricted `com.apple.developer.networking.wifi-info`
    /// entitlement, which requires enabling the capability on the App ID in Apple's developer
    /// portal — not something a free personal team can do. It is currently gated off in
    /// `project.yml`, which is also where the `HAVEN_WIFI_INFO` condition is defined and where the
    /// instructions for turning both back on live.
    ///
    /// This has to be a *compile-time* flag rather than a runtime probe because the entitlement's
    /// absence is indistinguishable from every other reason at runtime:
    /// `NEHotspotNetwork.fetchCurrent()` simply returns nil. Without this distinction the settings
    /// screen would tell a user sitting on Wi-Fi that they are "not on Wi-Fi" — a confident wrong
    /// answer — and would offer a Location Services prompt that cannot possibly help.
    static var isSSIDDetectionAvailable: Bool {
        #if HAVEN_WIFI_INFO
        true
        #else
        false
        #endif
    }

    /// Whether the SSID can be read at all right now. `false` is an entirely ordinary state.
    var canReadSSID: Bool {
        Self.isSSIDDetectionAvailable
            && (authorization == .authorizedWhenInUse || authorization == .authorizedAlways)
    }

    /// `true` only before the user has been asked — the settings surface uses this to decide
    /// between offering the prompt and pointing at the Settings app (iOS only ever prompts once).
    /// Always `false` while SSID detection is unavailable in this build: prompting for a
    /// privacy-sensitive permission we could not act on even if granted is worse than not asking.
    var canRequestPermission: Bool {
        Self.isSSIDDetectionAvailable && authorization == .notDetermined
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

    /// Records the current network as "home". Has two callers, deliberately sharing one
    /// implementation rather than two:
    ///
    /// 1. **`AppModel`, automatically**, after a connection whose **observed peer address** was
    ///    private — i.e. positive evidence we were on the home LAN, from the socket rather than from
    ///    anything self-reported.
    /// 2. **`ConnectionSettingsView`, explicitly**, when the user taps "Use this Wi-Fi network as my
    ///    home network". This is the only bootstrap path for a GUA-on-LAN home (see the type doc) —
    ///    there, `learnedOver` can never be `.local` from the address alone, so caller 1 never runs
    ///    until *after* caller 2 has already told the app which network is home.
    ///
    /// A no-op when the SSID can't be read, which is why granting permission later still works: the
    /// next local connection (or another tap of the settings button) captures it. Overwrites rather
    /// than appends — a single home network, matching the design's deferral of BSSID/multi-AP
    /// handling.
    func rememberCurrentNetworkAsHome() async {
        guard let ssid = await currentSSID(), !ssid.isEmpty else { return }
        guard ssid != homeSSID else { return }
        UserDefaults.standard.set(ssid, forKey: Self.homeSSIDKey)
        homeSSID = ssid
        havenLog.info("captured the home Wi-Fi network")
    }

    /// Cleared on sign-out with everything else that describes how to reach the old instance, and
    /// reachable directly from the settings screen as the explicit "forget this network" action.
    func forgetHomeNetwork() {
        UserDefaults.standard.removeObject(forKey: Self.homeSSIDKey)
        homeSSID = nil
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
