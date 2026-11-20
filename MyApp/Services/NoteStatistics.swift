import Foundation

/// Word/character statistics for the reader status bar, measured from the parsed blocks
/// so the raw Markdown syntax never reaches the counters.
nonisolated struct NoteStatistics: Sendable {
    let words: Int
    let characters: Int

    static let zero = NoteStatistics(words: 0, characters: 0)

    static func measure(blocks: [MarkdownBlock]) -> NoteStatistics {
        var fragments: [String] = []
        collect(blocks, into: &fragments)
        let text = fragments.joined(separator: " ")
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return NoteStatistics(words: words, characters: text.count)
    }

    static func readingMinutes(for words: Int) -> Int {
        guard words > 0 else { return 0 }
        // 220 words per minute is the usual French/English reading estimate.
        return max(1, Int(ceil(Double(words) / 220.0)))
    }

    private static func collect(_ blocks: [MarkdownBlock], into fragments: inout [String]) {
        for block in blocks {
            switch block.kind {
            case .heading(_, let text), .paragraph(let text):
                fragments.append(text.plainText)
            case .codeBlock(_, let code, _):
                fragments.append(code)
            case .blockQuote(let nested):
                collect(nested, into: &fragments)
            case .list(_, _, let items):
                for item in items {
                    collect(item.blocks, into: &fragments)
                }
            case .table(_, let headers, let rows):
                for header in headers {
                    fragments.append(header.plainText)
                }
                for row in rows {
                    for cell in row {
                        fragments.append(cell.plainText)
                    }
                }
            case .image(_, let alt):
                fragments.append(alt)
            case .thematicBreak:
                break
            }
        }
    }
}
