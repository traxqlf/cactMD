import SwiftUI

struct OutlinePopoverView: View {
    let headings: [NoteHeading]
    /// Section currently in view, highlighted so the panel shows where the
    /// reader is in the note.
    var activeHeadingID: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Plan de la note")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            if headings.isEmpty {
                Text("Aucun titre dans cette note.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(headings) { heading in
                            OutlineRow(
                                heading: heading,
                                isActive: heading.id == activeHeadingID
                            ) {
                                onSelect(heading.id)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 280)
    }
}

private struct OutlineRow: View {
    let heading: NoteHeading
    var isActive = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(heading.title.isEmpty ? "Sans titre" : heading.title)
                .font(.system(
                    size: heading.level == 1 ? 13 : 12.5,
                    weight: heading.level == 1 ? .semibold : .regular
                ))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, CGFloat(heading.level - 1) * 12)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isActive
                                ? Color.accentColor.opacity(0.14)
                                : Color.primary.opacity(isHovering ? 0.08 : 0)
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
    }
}
