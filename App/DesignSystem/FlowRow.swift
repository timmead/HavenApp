import SwiftUI

/// A row of views that wraps onto as many lines as it needs.
///
/// SwiftUI has no built-in flow layout, and the two obvious substitutes are both wrong: an
/// `HStack` clips whatever doesn't fit, and a horizontal `ScrollView` hides it behind a gesture.
/// Its first caller is `CameraModal`'s event chips, where a camera with a doorbell, a person sensor
/// and a motion sensor already overflows one line on a phone — and the doorbell is the chip that
/// must never be the hidden one.
///
/// Lives here rather than in that modal because nothing about it is camera-specific: it is a
/// `Layout` over arbitrary subviews, and the next chip row in this app would otherwise either
/// import it from a camera file or be written a second time.
struct FlowRow: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, projected > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
