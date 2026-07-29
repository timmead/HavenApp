import SwiftUI
import HavenCore

/// Haven's own configuration — the dashboard document — and the **only** thing that writes it.
///
/// Home Assistant owns the home: the devices, their readings, and which room they are in. This owns
/// the thin layer on top that HA has no opinion about — which of a room's several temperature
/// sources is *the* room's, and what the user calls a device.
///
/// **One writer, deliberately.** Two components each doing their own read-modify-write against one
/// versioned record means two retry loops racing on one version, and the loser silently reapplies
/// stale state. `EnvironmentCoordinator` used to own the document and its write path; it now keeps
/// the *resolution* — a domain rule — and routes its write-backs through `update` like everything
/// else.
@MainActor @Observable
final class HavenConfig {
    static let dashboardKey = "dashboard"

    /// The result of a write. An enum rather than a throw because `notAuthorized` is not a failure:
    /// only HA admins curate the shared dashboard, and for everyone else in the household that is
    /// the expected steady state. Callers explain it; nothing logs it as an error.
    enum Outcome: Equatable { case written, unchanged, notAuthorized, failed }

    private(set) var document = DashboardDocument()
    /// The version the held document was read at, and the base version of the next write.
    private(set) var version = 0
    /// Whether the document was *read*. False after a failure to read, and — critically — true for a
    /// home that simply has no configuration yet. Editing over a document we could not read is how a
    /// household's configuration gets overwritten, so this gates the mode.
    private(set) var isLoaded = false
    /// From `auth/current_user`. `nil` means the question could not be answered, which is not a yes:
    /// see `canConfigure`.
    private(set) var isAdmin: Bool?

    private var connection: HomeConnection?

    func attach(_ connection: HomeConnection?) {
        self.connection = connection
        isAdmin = nil
        isLoaded = false
    }

    func reset() {
        connection = nil
        document = DashboardDocument()
        version = 0
        isLoaded = false
        isAdmin = nil
    }

    /// Whether configuration mode may be entered at all.
    ///
    /// Four conditions, each sufficient to deny on its own, and each denying for a different reason:
    ///
    /// - **not a confirmed admin** — the `shared` scope is admin-writable only, and `nil` ("could not
    ///   find out") is not a yes. The cost is accepted: an admin whose probe failed has no
    ///   configuration entry until the next connect. The alternative offers a household member a
    ///   control that cannot act.
    /// - **not loaded** — see `isLoaded`.
    /// - **not writable** — a newer build wrote this document and we cannot know its invariants.
    /// - **not connected** — every edit is a write.
    var canConfigure: Bool {
        isAdmin == true && isLoaded && document.isWritable && connection != nil
    }

    /// Reads the shared dashboard record. Never throws: a configuration the app could not read must
    /// not take the dashboard down with it — the user still sees their home, they just cannot edit
    /// it.
    func load() async {
        guard let connection else { return }
        do {
            let record = try await connection.loadConfig(scope: HavenConfigScope.shared,
                                                         key: Self.dashboardKey)
            // An absent record is a successful read of a home with no configuration yet — the
            // ordinary first run — and must count as loaded. Only a throw means "we could not find
            // out".
            document = DashboardDocument(raw: record?.payload)
            version = record?.version ?? 0
            isLoaded = true
        } catch {
            havenLog.error("dashboard config unreadable: \(error)")
            document = DashboardDocument()
            version = 0
            isLoaded = false
        }
        // **Deliberately not awaited.** Admin status decides whether one menu item is drawn; it must
        // not decide how long the app takes to start, and awaiting it would put a round trip that
        // nothing on screen depends on into the critical path of `bootstrap()`. An instance that
        // never answers `auth/current_user` would hang the launch rather than cost the user a menu
        // item — which is how this was caught: `DashboardConfigWriteBackTests` scripts a socket that
        // answers only the commands the dashboard needs, and awaiting made it wait forever.
        //
        // `isAdmin` is observable and `canConfigure` reads it, so the entry appears when the answer
        // lands, a moment after the dashboard does.
        Task { await refreshAdminStatus() }
    }

    /// Asks Home Assistant whether this user is an admin.
    ///
    /// Separate from `load` so it can be awaited where the answer is the point — a test asserting
    /// the gate, or a future retry after a reconnect — while the launch path keeps firing it and
    /// moving on.
    func refreshAdminStatus() async {
        guard let connection else { return }
        isAdmin = await connection.fetchCurrentUserIsAdmin()
    }

    /// Applies an edit to the document and saves it.
    ///
    /// `mutate` is a *function of the current document* rather than a finished document, because a
    /// version conflict means someone else wrote first and the edit has to be reapplied to **their**
    /// document — applying our stale one would discard their change. That is also why the retry
    /// re-invokes the closure instead of resending the payload.
    ///
    /// One retry, then give up. A second conflict means a genuinely busy document, and nothing here
    /// is time-critical enough to spin on.
    @discardableResult
    func update(_ mutate: @MainActor (DashboardDocument) -> DashboardDocument) async -> Outcome {
        await attemptUpdate(mutate, isRetry: false)
    }

    private func attemptUpdate(_ mutate: @MainActor (DashboardDocument) -> DashboardDocument,
                               isRetry: Bool) async -> Outcome {
        // **Never write over a document we could not read.** `isLoaded` is false only after a failed
        // read — an absent record is a successful read of a home with no configuration yet — and
        // writing then would replace a household's whole configuration with whatever this device
        // happens to have derived from nothing.
        //
        // The gate is here rather than only in `canConfigure` because the automatic nomination
        // write-back is not a user edit and never consults the mode: the previous version of this
        // code enforced the rule by simply not calling its write path in the failure branch, and
        // moving the write behind one entry point is what turned "the caller happens not to call it"
        // into something that has to be stated.
        guard let connection, isLoaded, document.isWritable else { return .failed }
        let merged = mutate(document)
        // A no-op write would churn the shared record's version and `updated_by` for nothing, which
        // the rest of the household sees as somebody editing the dashboard.
        guard merged != document else { return .unchanged }
        do {
            switch try await connection.saveConfig(scope: HavenConfigScope.shared,
                                                   key: Self.dashboardKey,
                                                   baseVersion: version, payload: merged.raw) {
            case .ok(let newVersion):
                document = merged
                version = newVersion
                return .written
            case .versionConflict(let current):
                document = DashboardDocument(raw: current?.payload)
                version = current?.version ?? 0
                guard !isRetry else { return .failed }
                return await attemptUpdate(mutate, isRetry: true)
            }
        } catch let error as WSError where error.isNotAuthorized {
            // New evidence about a question we thought we had answered: this user is not an admin
            // after all, or has just been demoted. Recording it here is what makes the mode close
            // itself — `canConfigure` goes false, and `DashboardView` watches that — so "explain and
            // leave configuration mode" needs no separate wiring in each sheet.
            isAdmin = false
            return .notAuthorized
        } catch {
            havenLog.error("could not write dashboard config: \(error)")
            return .failed
        }
    }
}

#if DEBUG
extension HavenConfig {
    /// Drives `canConfigure`'s inputs directly, so the gate can be tested without four sockets.
    func setForTesting(isAdmin: Bool?, isLoaded: Bool, isWritable: Bool, isConnected: Bool) {
        self.isAdmin = isAdmin
        self.isLoaded = isLoaded
        self.document = isWritable
            ? DashboardDocument()
            : DashboardDocument(raw: .object(["schema": .int(DashboardDocument.schema + 1)]))
        self.connection = isConnected
            ? HomeConnection(client: HAWebSocketClient(connection: NeverAnsweringSocket()))
            : nil
    }

    /// Seeds the held document directly, for previews of views that render configuration.
    func seedForTesting(_ document: DashboardDocument) {
        self.document = document
        self.isLoaded = true
    }
}

/// A socket that never answers. Only ever used to make `connection != nil` true in a gate test or a
/// preview — nothing is ever sent through it.
private struct NeverAnsweringSocket: WebSocketConnection {
    func connect() async throws {}
    func close() {}
    func send(_ data: Data) async throws {}
    func receive() async throws -> Data {
        try await Task.sleep(for: .seconds(86_400))
        return Data()
    }
}
#endif
