import SwiftUI

/// Discreet word/character/reading-time line under the reading column.
struct ReaderStatusBar: View {
    let note: LoadedNote

    private var minutes: Int {
        NoteStatistics.readingMinutes(for: note.wordCount)
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(height: 1)

            HStack(spacing: 10) {
                Text("\(note.wordCount.formatted()) \(note.wordCount == 1 ? "mot" : "mots")")
                separator
                Text("\(note.characterCount.formatted()) \(note.characterCount == 1 ? "caractère" : "caractères")")
                separator
                Text(minutes == 0 ? "Lecture < 1 min" : "\(minutes) min de lecture")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .frame(maxWidth: 750, alignment: .center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 44)
            .padding(.vertical, 6)
        }
        .background(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(note.wordCount) mots, \(note.characterCount) caractères, \(minutes) minute\(minutes == 1 ? "" : "s") de lecture"
        )
    }

    private var separator: some View {
        Text("·")
            .foregroundStyle(.quaternary)
    }
}
