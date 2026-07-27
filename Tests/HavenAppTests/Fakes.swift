import Foundation
import SwiftUI
import HavenCore
@testable import HavenApp

/// A `TokenStore` that lives entirely in memory.
///
/// Injected into every `AppModel` this suite builds so nothing here can read, refresh or clear the
/// developer's real Keychain entry — and so `restoreIfPossible()` cannot decide there is a session
/// worth dialling. Hermetic by construction rather than by remembering not to call something.
final class FakeTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: HATokens?
    private(set) var clearCount = 0

    init(tokens: HATokens? = nil) { self.tokens = tokens }

    func save(_ tokens: HATokens) throws {
        lock.lock(); defer { lock.unlock() }
        self.tokens = tokens
    }

    func load() -> HATokens? {
        lock.lock(); defer { lock.unlock() }
        return tokens
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        tokens = nil
        clearCount += 1
    }
}

/// A `UserDefaults` in its own suite, wiped before use.
///
/// Tests must never write to the standard domain: under a hosted test bundle that domain belongs to
/// the running app, so a test asserting "the remote URL was adopted" would leave a real adopted URL
/// behind for the next launch of the app to dial.
@MainActor
func makeTestDefaults(_ name: String = #function) -> UserDefaults {
    let suite = "HavenAppTests.\(name)"
    UserDefaults().removePersistentDomain(forName: suite)
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

/// The environment `RootView` needs, supplied the same way `HavenAppApp` supplies it, so what the
/// probe renders is the real screen and not a stand-in.
struct RootViewHarness: View {
    let model: AppModel
    var body: some View {
        RootView().environment(model)
    }
}
