import Foundation

nonisolated enum MarkdownTagScanner {
    private static let tagRegex = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_/])#(\p{L}[\p{L}\p{N}_/-]*)"#
    )

    /// Body tags only: headings, fenced code blocks and inline code are ignored.
    // shortcut: indented code blocks still count; fenced code covers the common case.
    static func tags(in body: String) -> [String] {
        guard let regex = tagRegex else { return [] }

        var seen = Set<String>()
        var result: [String] = []
        var inFence = false

        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }

            if trimmed.hasPrefix("#") {
                let afterHashes = trimmed.drop(while: { $0 == "#" })
                if afterHashes.isEmpty || afterHashes.first == " " { continue }
            }

            let sanitized = strippingInlineCode(line)
            let nsLine = sanitized as NSString
            let matches = regex.matches(
                in: sanitized,
                range: NSRange(location: 0, length: nsLine.length)
            )

            for match in matches {
                let tag = nsLine.substring(with: match.range(at: 1))
                guard seen.insert(tag.lowercased()).inserted else { continue }
                result.append(tag)
            }
        }

        return result
    }

    private static func strippingInlineCode(_ line: String) -> String {
        var output = ""
        var inCode = false
        for character in line {
            if character == "`" {
                inCode.toggle()
                output.append(" ")
            } else if !inCode {
                output.append(character)
            }
        }
        return output
    }
}

nonisolated enum TagIndexService {
    static func build(for notes: [NoteReference]) async -> [URL: Set<String>] {
        var index: [URL: Set<String>] = [:]
        let batchSize = 8

        for start in stride(from: 0, to: notes.count, by: batchSize) {
            if Task.isCancelled { break }
            let end = min(start + batchSize, notes.count)
            let batch = Array(notes[start..<end])

            let partial = await withTaskGroup(of: (URL, Set<String>).self) { group in
                for note in batch {
                    group.addTask {
                        (note.url, Set(tags(in: note.url)))
                    }
                }
                var collected: [(URL, Set<String>)] = []
                for await item in group {
                    collected.append(item)
                }
                return collected
            }

            for (url, tags) in partial {
                index[url] = tags
            }
        }

        return index
    }

    private static func tags(in url: URL) -> [String] {
        let source = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        guard let source else { return [] }
        let body = FrontmatterParser.split(source).body
        return MarkdownTagScanner.tags(in: body)
    }
}
