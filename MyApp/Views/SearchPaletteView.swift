import AppKit
import SwiftUI

private struct SearchGroup: Identifiable {
    let note: NoteReference
    var hits: [SearchHit]

    var id: URL { note.url }
}

struct SearchPaletteView: View {
    let store: WorkspaceStore

    @State private var query = ""
    @State private var selection = 0

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()

            if flattenedHits.isEmpty {
                emptyState
            } else {
                resultsList
            }

            Divider()
            hintsBar
        }
        .frame(width: 640)
        .floatingGlassPanel()
        .onChange(of: query) { _, _ in
            selection = 0
            store.updateSearchQuery(query)
        }
        .onChange(of: store.searchHits.count) { _, count in
            if selection >= count {
                selection = max(0, count - 1)
            }
        }
        .onExitCommand {
            store.dismissSearch()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)

            PaletteSearchField(
                text: $query,
                placeholder: "Rechercher dans les notes…",
                fontSize: 19,
                onQueryChange: { _ in selection = 0 },
                onMove: { delta in
                    guard !flattenedHits.isEmpty else { return }
                    selection = min(max(selection + delta, 0), flattenedHits.count - 1)
                },
                onSubmit: { openSelection() },
                onCancel: { store.dismissSearch() }
            )
            .frame(height: 28)

            if store.isSearching {
                ProgressView()
                    .controlSize(.small)
            }

            Text("⌘⇧F")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(groups) { group in
                        // Note name, then its parent folder: two notes with the
                        // same name in different folders stay distinguishable.
                        HStack(spacing: 6) {
                            Text(group.note.name)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            if !group.note.folder.isEmpty {
                                Text(group.note.folder)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 7)

                        ForEach(group.hits) { hit in
                            resultRow(hit)
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 380)
            .onChange(of: selection) { _, newValue in
                guard newValue < flattenedHits.count else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(flattenedHits[newValue].id, anchor: .center)
                }
            }
        }
    }

    private func resultRow(_ hit: SearchHit) -> some View {
        Button {
            open(hit)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                // A name-only match carries no line: keep the gutter, hide the
                // number instead of printing a fake 0.
                Text(hit.line > 0 ? "\(hit.line)" : "")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 34, alignment: .trailing)
                    .padding(.top, 1)

                Text(highlighted(hit.snippet))
                    .font(.system(size: 11.5))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected(hit) ? Color.accentColor.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(hit.id)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            if store.isSearching {
                ProgressView()
                    .controlSize(.small)
                Text("Recherche…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if trimmedQuery.isEmpty {
                Text("Rechercher dans le contenu de toutes les notes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Aucun résultat pour « \(trimmedQuery) ».")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private var hintsBar: some View {
        HStack(spacing: 14) {
            hint("↑↓", "Naviguer")
            hint("⏎", "Ouvrir")
            hint("esc", "Fermer")
            Spacer()
            Text(resultCountLabel)
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

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var flattenedHits: [SearchHit] {
        store.searchHits
    }

    private var groups: [SearchGroup] {
        var result: [SearchGroup] = []
        for hit in store.searchHits {
            if let last = result.last, last.note.url == hit.note.url {
                result[result.count - 1].hits.append(hit)
            } else {
                result.append(SearchGroup(note: hit.note, hits: [hit]))
            }
        }
        return result
    }

    private var resultCountLabel: String {
        let count = store.searchHits.count
        guard count > 0 else { return "" }
        return "\(count) résultat\(count > 1 ? "s" : "")"
    }

    private func isSelected(_ hit: SearchHit) -> Bool {
        flattenedHits.indices.contains(selection) && flattenedHits[selection].id == hit.id
    }

    private func openSelection() {
        guard flattenedHits.indices.contains(selection) else { return }
        open(flattenedHits[selection])
    }

    private func open(_ hit: SearchHit) {
        store.openSearchHit(hit)
    }

    private func highlighted(_ text: String) -> AttributedString {
        let needle = trimmedQuery
        guard !needle.isEmpty else { return AttributedString(text) }

        var output = AttributedString()
        var remaining = text[...]

        while let range = remaining.range(
            of: needle,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) {
            var plain = AttributedString(String(remaining[..<range.lowerBound]))
            plain.font = .system(size: 11.5)
            output.append(plain)

            var match = AttributedString(String(remaining[range]))
            match.font = .system(size: 11.5, weight: .semibold)
            match.backgroundColor = Color.accentColor.opacity(0.3)
            output.append(match)

            remaining = remaining[range.upperBound...]
        }

        var tail = AttributedString(String(remaining))
        tail.font = .system(size: 11.5)
        output.append(tail)
        return output
    }
}
