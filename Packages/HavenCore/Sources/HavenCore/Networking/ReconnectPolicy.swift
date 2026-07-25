import Foundation

public struct ReconnectPolicy: Sendable {
    public let base: Duration
    public let max: Duration
    public init(base: Duration = .seconds(3), max: Duration = .seconds(30)) {
        self.base = base; self.max = max
    }
    public func delay(forAttempt n: Int) -> Duration {
        let scaled = base * n
        return scaled < max ? scaled : max
    }
}
