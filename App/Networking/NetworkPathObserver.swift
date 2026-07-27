import Foundation
import Network
import HavenCore

/// Layer 2 of the home-detection stack: reports which kind of interface the device is currently
/// using, via `NWPathMonitor`. **No permissions of any kind**, no prompt, nothing the user has to
/// agree to — which is exactly why it is the layer that always runs.
///
/// ## What this tells you, stated precisely
///
/// It distinguishes **Wi-Fi from cellular**. It does **not** distinguish **home Wi-Fi from a
/// café's** — nothing in `NWPath` can, and no amount of extra inspection here would change that.
/// So `.wifi` means only "a LAN address is worth probing"; it never means "we are home". The layer
/// that can tell home from elsewhere is the SSID match (`HomeNetwork`), and it is optional.
///
/// Deliberately holds **no ordering logic**. It converts an `NWPath` into the `NetworkPathClass`
/// that `ConnectionPreference` — a pure, unit-tested function in HavenCore — makes decisions from.
/// Nothing here is exercised by `Tests/HavenAppTests` — a decision made in this file would be a
/// claim nobody checks, so no decision is made in it.
@MainActor @Observable
final class NetworkPathObserver {
    /// The current interface class. Starts at `.other`, which is the correct "no signal yet" value:
    /// `ConnectionPreference` treats `.other` like Wi-Fi (probe local first), so a connect attempt
    /// racing the first path update behaves as if this layer were simply unavailable — layer 3.
    private(set) var pathClass: NetworkPathClass = .other

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.haven.pathmonitor")

    /// Started immediately and never cancelled: this object lives as long as `AppModel`, i.e. the
    /// whole app, so there is no lifetime to manage and a `deinit` would only add an
    /// isolation-crossing teardown for a case that cannot occur.
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            // Classified here, off the main actor, so only a `Sendable` enum crosses back — an
            // `NWPath` is not something to hand to the main actor.
            let observed = NetworkPathObserver.classify(path)
            Task { @MainActor in self?.pathClass = observed }
        }
        monitor.start(queue: queue)
    }

    /// Wi-Fi is checked first: on the rare path that reports both (e.g. Wi-Fi Assist active), a
    /// LAN address may still answer, and the cost of finding out is one 2s probe.
    ///
    /// `nonisolated` because `NWPathMonitor` delivers updates on its own queue and this is pure
    /// mapping — reading an `NWPath`, returning a `Sendable` enum. Hopping to the main actor just
    /// to run it would mean sending the `NWPath` itself across, which is the thing to avoid.
    nonisolated private static func classify(_ path: NWPath) -> NetworkPathClass {
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        // Wired, unknown, or no path at all. Same treatment as Wi-Fi — a LAN address might well
        // answer, and layer 3 exists precisely to find out cheaply.
        return .other
    }
}
