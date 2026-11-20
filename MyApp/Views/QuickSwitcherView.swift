import AppKit
import SwiftUI

struct QuickSwitcherView: View {
    let store: WorkspaceStore

    @State private var query = ""
    @State private var selection = 0

    var body: some View {
        VStack(spacing: 0) {
            searchBar

            if rowCount > 0 {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, note in
                                resultRow(
                                    index: index,
                                    title: note.name,
                                    subtitle: note.folder,
                                    systemImage: "doc.text"
                                )
                            }

                            if createCandidate != nil {
                                resultRow(
                                    index: matches.count,
                                    title: "Créer « \(displayQuery) »",
                                    subtitle: "Nouvelle note Markdown",
                                    systemImage: "plus.circle"
                                )
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 330)
                    .onChange(of: selection) { _, newValue in
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            } else {
                Text("Aucune note ne correspond.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
            }

            Divider()
            hintsBar
        }
        .frame(width: 560)
        .floatingGlassPanel()
        .onChange(of: query) { _, _ in
            selection = 0
        }
        .onChange(of: rowCount) { _, newValue in
            if selection >= newValue {
                selection = max(0, newValue - 1)
            }
        }
        .onExitCommand {
            store.dismissQuickSwitcher()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)

            PaletteSearchField(
                text: $query,
                placeholder: "Rechercher une note…",
                onQueryChange: { _ in selection = 0 },
                onMove: { delta in
                    guard rowCount > 0 else { return }
                    selection = min(max(selection + delta, 0), rowCount - 1)
                },
                onSubmit: { activateSelection() },
                onCancel: { store.dismissQuickSwitcher() }
            )
            .frame(height: 28)

            Text("esc")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var hintsBar: some View {
        HStack(spacing: 14) {
            hint("↑↓", "Naviguer")
            hint("⏎", "Ouvrir")
            hint("esc", "Fermer")
            Spacer()
            Text("\(matches.count) note\(matches.count > 1 ? "s" : "")")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    private func resultRow(index: Int, title: String, subtitle: String, systemImage: String) -> some View {
        Button {
            activate(at: index)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(index == selection ? Color.accentColor : Color.secondary)
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 12)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(index == selection ? Color.accentColor.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(index)
    }

    private var displayQuery: String {
        strippingExtension(query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func strippingExtension(_ value: String) -> String {
        let lowercased = value.lowercased()
        if lowercased.hasSuffix(".markdown") {
            return String(value.dropLast(9))
        }
        if lowercased.hasSuffix(".md") {
            return String(value.dropLast(3))
        }
        return value
    }

    private var matches: [NoteReference] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Array(store.allNotes.prefix(50))
        }

        let needle = strippingExtension(trimmed).lowercased()
        guard !needle.isEmpty else { return [] }

        let scored: [(note: NoteReference, score: Int)] = store.allNotes.compactMap { note in
            guard let score = Self.score(note, needle: needle) else { return nil }
            return (note, score)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.note.name.localizedStandardCompare(rhs.note.name) == .orderedAscending
            }
            .map(\.note)
    }

    /// Fuzzy match on the title first, then on the relative path. Ties are
    /// broken in favour of the tighter match, so “cr” lists “Compte-rendu”
    /// before “Culture cellulaire” only when the initials really line up.
    private static func score(_ note: NoteReference, needle: String) -> Int? {
        let name = note.name.lowercased()
        if name == needle { return 10_000 }
        if name.hasPrefix(needle) { return 9_000 }
        if let range = name.range(of: needle) {
            let distance = name.distance(from: name.startIndex, to: range.lowerBound)
            return 7_000 - distance
        }
        if let fuzzy = subsequenceScore(name, needle) { return 5_000 + fuzzy }

        let path = note.relativePath.lowercased()
        if let range = path.range(of: needle) {
            let distance = path.distance(from: path.startIndex, to: range.lowerBound)
            return 3_000 - distance
        }
        if let fuzzy = subsequenceScore(path, needle) { return 1_000 + fuzzy }
        return nil
    }

    /// Every needle character must appear in order; word starts score higher so
    /// “fr” still finds “Fiche de révision”.
    private static func subsequenceScore(_ haystack: String, _ needle: String) -> Int? {
        var score = 0
        var index = haystack.startIndex
        var atWordStart = true

        for character in needle {
            var matched = false
            while index < haystack.endIndex {
                let current = haystack[index]
                if current == character {
                    score += atWordStart ? 8 : 2
                    index = haystack.index(after: index)
                    matched = true
                    atWordStart = false
                    break
                }
                atWordStart = isSeparator(current)
                index = haystack.index(after: index)
            }
            guard matched else { return nil }
        }
        return score
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character == " " || character == "-" || character == "_"
            || character == "/" || character == "." || character == "(" || character == "["
    }

    private var createCandidate: String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let stem = strippingExtension(trimmed)
        guard !stem.isEmpty else { return nil }
        let hasExactMatch = store.allNotes.contains {
            $0.name.caseInsensitiveCompare(stem) == .orderedSame
                || $0.relativePathWithoutExtension.caseInsensitiveCompare(stem) == .orderedSame
        }
        return hasExactMatch ? nil : trimmed
    }

    private var rowCount: Int {
        matches.count + (createCandidate == nil ? 0 : 1)
    }

    private func activateSelection() {
        activate(at: selection)
    }

    private func activate(at rawIndex: Int) {
        guard rowCount > 0 else { return }
        let index = min(max(rawIndex, 0), rowCount - 1)

        if index < matches.count {
            let note = matches[index]
            store.dismissQuickSwitcher()
            store.openNote(at: note.url)
        } else if let name = createCandidate {
            store.dismissQuickSwitcher()
            store.createNote(named: name)
        }
    }
}

struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Rechercher…"
    var fontSize: CGFloat = 21
    let onQueryChange: (String) -> Void
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize, weight: .regular)
        field.placeholderString = placeholder
        field.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.stringValue = text

        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }

        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text, nsView.currentEditor() == nil {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteSearchField

        init(parent: PaletteSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onQueryChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}
