import SwiftUI
import HavenCore
struct GenericModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId)
        VStack(spacing: 12) {
            // The accent here was already `.gray`, so this modal never *looked* wrong — but it
            // named the state only by echoing the raw string. Answering the question explicitly
            // gets it the same "Unavailable" wording as every other header.
            ModalHeader(systemImage: IconMap.symbol(domain: .unknown, deviceClass: e?.deviceClass),
                        title: TileName.of(entityId, e), subtitle: e?.state ?? "—",
                        accent: .gray, unavailable: e?.isUnavailable ?? false)
            FacetCard(title: "Attributes") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach((e?.attributes.keys.sorted() ?? []), id: \.self) { k in
                        HStack { Text(k).font(.caption).foregroundStyle(.secondary); Spacer(); Text(display(e?.attributes[k] ?? .null)).font(.caption).lineLimit(1) }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(k), \(display(e?.attributes[k] ?? .null))")
                    }
                }
            }
        }
    }

    /// Renders a `JSONValue`'s underlying value for display, never its enum case syntax.
    private func display(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): return s
        case .int(let i): return String(i)
        // Home Assistant sends integral values as JSON doubles routinely (a `42` brightness
        // arrives as `42.0`), and `String(_: Double)` always writes the decimal point. Rendering a
        // whole number as "42.0" in an attribute list makes it look like a precision the device
        // does not have.
        case .double(let d):
            return d == d.rounded() && abs(d) < 1e15
                ? String(Int(d))
                : String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "—"
        case .array(let a): return a.map(display).joined(separator: ", ")
        case .object(let o): return o.sorted { $0.key < $1.key }.map { "\($0.key): \(display($0.value))" }.joined(separator: ", ")
        }
    }
}
