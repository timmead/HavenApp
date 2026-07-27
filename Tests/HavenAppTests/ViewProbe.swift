import UIKit
import SwiftUI

/// Renders a SwiftUI view for real and reports the text a user would be able to see and act on.
///
/// **Why the real hierarchy and not a predicate.** The defect this exists to catch is "connection
/// settings were reachable only from `DashboardView`, i.e. only once already connected" — a
/// *reachability* claim. A `Bool` on an enum saying "reachable: true" is not that claim; it is a
/// second copy of it that a `RootView` change can silently contradict, which is exactly how a
/// security fix once shipped with 107 green tests over a helper predicate while the real decision
/// went unexercised. So the view is hosted in a window and the resulting tree is searched.
@MainActor
enum ViewProbe {
    /// Hosts `view`, lays it out, and returns every accessibility label in the resulting tree.
    ///
    /// The wait is a bounded poll rather than a sleep: it returns the instant the tree contains
    /// anything at all, and only spends wall-clock when there is genuinely nothing to find — so a
    /// pass is immediate and deterministic, and only a failure is slow.
    static func labels<V: View>(in view: V, timeout: TimeInterval = 5) -> Set<String> {
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.isHidden = false
        window.makeKeyAndVisible()

        let deadline = Date().addingTimeInterval(timeout)
        var found: Set<String> = []
        repeat {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            found = collect(from: host.view)
            if !found.isEmpty { break }
            // One run-loop turn, so SwiftUI can commit its render. Not a fixed wait — the loop
            // exits on the first non-empty tree.
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline

        window.isHidden = true
        window.rootViewController = nil
        return found
    }

    /// Walks both trees a SwiftUI view can put its text in: the `UIView` subtree, and the
    /// accessibility elements a view vends in place of real subviews (which is how SwiftUI renders
    /// most text and controls).
    private static func collect(from view: UIView) -> Set<String> {
        var out: Set<String> = []
        func visit(_ node: Any) {
            if let object = node as? NSObject {
                if let label = object.accessibilityLabel, !label.isEmpty { out.insert(label) }
                if let value = object.accessibilityValue, !value.isEmpty { out.insert(value) }
                let count = object.accessibilityElementCount()
                if count != NSNotFound && count > 0 {
                    for index in 0..<count {
                        if let child = object.accessibilityElement(at: index) { visit(child) }
                    }
                }
            }
            if let view = node as? UIView {
                for sub in view.subviews { visit(sub) }
            }
        }
        visit(view)
        return out
    }
}
