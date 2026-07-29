import SwiftUI

/// One row of an entity picker: what the thing is called, over the id that identifies it.
///
/// **The id is on the row deliberately.** Two sensors in one room are routinely both called
/// "Temperature" — Home Assistant names entities after the measurement, not the place — so a picker
/// showing names alone asks the user to choose between two identical rows. The id is the only thing
/// that always tells them apart.
///
/// A shared component rather than part of the room sheet, because the tile, add-tile and composite
/// flows all need this same row and should not each grow their own.
struct EntityPickerRow: View {
    /// The display name, already resolved through `DisplayName` by the caller — so a device the user
    /// renamed reads that way here too.
    let title: String
    let entityId: String
    /// An optional third fact: which attribute is read, or anything else the id does not say. Nil
    /// where the id says everything.
    var detail: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(entityId)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // Middle, not tail: entity ids share their prefix (`sensor.lounge_…`) and differ
                    // at the end, so trimming the tail hides the only distinguishing part.
                    .truncationMode(.middle)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            // A checkmark, not a tint on the row: the row already carries two or three lines of text
            // and a coloured wash behind them is the least readable way to say "this one".
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(HavenColor.domain(.cover))
                .opacity(isSelected ? 1 : 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
