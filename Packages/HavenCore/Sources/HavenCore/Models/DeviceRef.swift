public enum DeviceRef: Sendable, Equatable, Identifiable {
    case entity(String)
    case composite(type: String, inputs: [String: String])   // abstraction only in D
    public var id: String {
        switch self {
        case .entity(let e): return e
        case .composite(let t, let inputs): return "composite:\(t):" + inputs.keys.sorted().map { "\($0)=\(inputs[$0]!)" }.joined(separator: ",")
        }
    }
}
