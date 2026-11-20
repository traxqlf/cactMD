import Foundation

nonisolated struct SearchHit: Identifiable, Sendable {
    let note: NoteReference
    let line: Int
    let snippet: String

    var id: String { "\(note.url.path)#\(line)" }
}

/// Reads one file at a time per worker and keeps only the matching lines, so the
/// whole vault never sits in memory.
nonisolated enum FullTextSearchService {
    static let maxHits = 200
    private static let maxHitsPerNote = 6
    private static let batchSize = 8

    static func search(query: String, in notes: [NoteReference]) async -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        var hits: [SearchHit] = []

        for start in stride(from: 0, to: notes.count, by: batchSize) {
            if Task.isCancelled || hits.count >= maxHits { break }
            let end = min(start + batchSize, notes.count)
            let batch = Array(notes[start..<end])

            let partial = await withTaskGroup(of: [SearchHit].self) { group in
                for note in batch {
                    group.addTask {
                        scan(note: note, needle: needle)
                    }
                }
                var collected: [SearchHit] = []
                for await item in group {
                    collected.append(contentsOf: item)
                }
                return collected
            }

            hits.append(contentsOf: partial)
        }

        return ordered(hits)
    }

    /// Snippets for the handful of notes Spotlight already matched.
    ///
    /// Reading these files is the only disk work a Spotlight query costs, and
    /// it is bounded by the candidate list, not by the size of the vault. A note
    /// that matched on its *name* only still gets one hit, so a filename query
    /// never comes back empty just because no line contains the word.
    static func hits(query: String, in urls: [URL], relativeTo root: URL?) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        var collected: [SearchHit] = []
        for url in urls {
            if Task.isCancelled || collected.count >= maxHits { break }
            let name = url.deletingPathExtension().lastPathComponent
            let relative = relativePath(of: url, in: root)
            let note = NoteReference(
                url: url,
                name: name,
                relativePath: relative,
                folder: (relative as NSString).deletingLastPathComponent
            )

            let matches = scan(note: note, needle: needle)
            if matches.isEmpty {
                guard name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil else {
                    continue
                }
                // Line 0 marks a name match: the palette shows no line number.
                collected.append(SearchHit(note: note, line: 0, snippet: name))
            } else {
                collected.append(contentsOf: matches)
            }
        }

        return ordered(collected)
    }

    private static func ordered(_ hits: [SearchHit]) -> [SearchHit] {
        Array(
            hits
                .sorted { lhs, rhs in
                    if lhs.note.name != rhs.note.name {
                        return lhs.note.name.localizedStandardCompare(rhs.note.name) == .orderedAscending
                    }
                    if lhs.note.relativePath != rhs.note.relativePath {
                        return lhs.note.relativePath.localizedStandardCompare(rhs.note.relativePath) == .orderedAscending
                    }
                    return lhs.line < rhs.line
                }
                .prefix(maxHits)
        )
    }

    private static func relativePath(of url: URL, in root: URL?) -> String {
        guard let root else { return url.lastPathComponent }
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(base.count + 1))
    }

    private static func scan(note: NoteReference, needle: String) -> [SearchHit] {
        let source = (try? String(contentsOf: note.url, encoding: .utf8))
            ?? (try? String(contentsOf: note.url, encoding: .isoLatin1))
        guard let source else { return [] }

        var hits: [SearchHit] = []
        var lineNumber = 0
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  trimmed.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil else {
                continue
            }

            hits.append(
                SearchHit(
                    note: note,
                    line: lineNumber,
                    snippet: makeSnippet(trimmed, needle: needle)
                )
            )

            if hits.count >= maxHitsPerNote { break }
        }

        return hits
    }

    private static func makeSnippet(_ line: String, needle: String) -> String {
        let text = line.replacingOccurrences(of: "\t", with: " ")
        let nsText = text as NSString
        guard nsText.length > 180 else { return text }

        let match = nsText.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
        guard match.location != NSNotFound else { return text }

        let start = max(0, min(match.location - 60, nsText.length - 180))
        let snippet = nsText.substring(with: NSRange(location: start, length: 180))
        let leading = start > 0 ? "…" : ""
        let trailing = start + 180 < nsText.length ? "…" : ""
        return leading + snippet + trailing
    }
}
