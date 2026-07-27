import SwiftUI
import Foundation

@main
struct HavenAppApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // **Not started under `xcodebuild test`.** A hosted unit-test bundle launches the
                // real app before it loads the tests, so without this guard the first thing the
                // suite does is restore the developer's saved session and open a WebSocket to
                // their actual Home Assistant — observed, with `auth_ok` in the log, the first
                // time this target ran. A test suite that talks to the user's house is not
                // hermetic, is not repeatable, and can issue commands to real devices in a real
                // home.
                //
                // This is the *only* thing the guard suppresses, and it suppresses nothing in a
                // shipped build: `XCTestConfigurationFilePath` is set by the test runner and by
                // nothing else, so App Store and development launches are byte-for-byte unchanged.
                // Tests that want a session construct their own `AppModel` with injected
                // dependencies (see `AppModel.init(defaults:tokens:)`).
                .task { if !HavenAppApp.isRunningTests { await model.restoreIfPossible() } }
        }
    }

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
