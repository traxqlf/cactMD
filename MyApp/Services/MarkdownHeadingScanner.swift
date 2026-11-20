import Foundation

/// Finds ATX headings (`#` … `######`) in raw Markdown source.
///
/// The parser gives the reader a block tree with opaque ids; the editor works on
/// the raw text and needs *character offsets* instead. Both lists walk the note
/// in document order, so the outline can map a heading to the editor with one
/// scan — no per-keystroke work.
nonisolated enum MarkdownHeadingScanner {
    struct Heading: Equatable, Sendable {
        let level: Int
        let title: String
        /// UTF-16 offset of the `#` in the source, matching `NSString` indices.
        let offset: Int
    }

    static func headings(in text: String) -> [Heading] {
        var result: [Heading] = []
        var offset = 0
        var fenceMarker: Character?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let current = String(line)
            let trimmed = current.drop { $0 == " " || $0 == "\t" }

            if let marker = fenceMarker {
                if trimmed.hasPrefix(String(repeating: marker, count: 3)) {
                    fenceMarker = nil
                }
            } else if trimmed.hasPrefix("```") {
                fenceMarker = "`"
            } else if trimmed.hasPrefix("~~~") {
                fenceMarker = "~"
            } else if let heading = parseHeading(current) {
                result.append(Heading(level: heading.level, title: heading.title, offset: offset))
            }

            offset += current.utf16.count + 1
        }

        return result
    }

    /// Heading closest to `sourceIndex` that starts at or above it, used to keep
    /// the outline in sync with the caret and the scroll position.
    static func headingIndex(atOrBefore sourceIndex: Int, in headings: [Heading]) -> Int? {
        guard !headings.isEmpty else { return nil }
        var low = 0
        var high = headings.count - 1
        var found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if headings[middle].offset <= sourceIndex {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }

    private static func parseHeading(_ line: String) -> (level: Int, title: String)? {
        var cursor = line.startIndex
        var spaces = 0
        while cursor < line.endIndex, spaces < 4, line[cursor] == " " {
            cursor = line.index(after: cursor)
            spaces += 1
        }
        guard spaces < 4, cursor < line.endIndex, line[cursor] == "#" else { return nil }

        var level = 0
        while cursor < line.endIndex, level < 6, line[cursor] == "#" {
            level += 1
            cursor = line.index(after: cursor)
        }
        guard level > 0, cursor < line.endIndex,
              line[cursor] == " " || line[cursor] == "\t" else {
            return nil
        }

        while cursor < line.endIndex, line[cursor] == " " || line[cursor] == "\t" {
            cursor = line.index(after: cursor)
        }

        var title = String(line[cursor...]).trimmingCharacters(in: .whitespaces)
        // ATX closing sequence: `## Titre ##` has no trailing hashes in its title.
        while let last = title.last, last == "#" {
            title.removeLast()
        }
        return (level, title.trimmingCharacters(in: .whitespaces))
    }
}
