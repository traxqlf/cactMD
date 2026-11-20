import Foundation

nonisolated enum BacklinkScanner {
    // shortcut: byte-level scan, so a [[...]] literal inside a code fence counts as a backlink.
    // Upgrade to a Markdown AST scan if vaults with large code samples need exact backlinks.
    private static let opening = Data("[[".utf8)
    private static let closing = Data("]]".utf8)

    static func findBacklinks(to target: String, in notes: [NoteReference]) -> [NoteReference] {
        let normalizedTarget = normalize(target)
        guard !normalizedTarget.isEmpty else { return [] }

        var results: [NoteReference] = []

        for note in notes {
            let found: Bool = autoreleasepool {
                // Mapped read: the pages touched here are released with the Data, no full String copy.
                guard let data = try? Data(contentsOf: note.url, options: [.mappedIfSafe]),
                      data.range(of: opening) != nil else {
                    return false
                }
                return containsLink(to: normalizedTarget, in: data)
            }

            if found {
                results.append(note)
            }
        }

        return results.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func containsLink(to normalizedTarget: String, in data: Data) -> Bool {
        var searchStart = data.startIndex

        while searchStart < data.endIndex,
              let openRange = data.range(of: opening, options: [], in: searchStart..<data.endIndex) {
            let contentStart = openRange.upperBound
            guard contentStart < data.endIndex,
                  let closeRange = data.range(of: closing, options: [], in: contentStart..<data.endIndex) else {
                return false
            }

            let content = data[contentStart..<closeRange.lowerBound]
            if !content.contains(UInt8(ascii: "[")) {
                if let raw = String(data: content, encoding: .utf8),
                   matches(raw, target: normalizedTarget) {
                    return true
                }
            }

            searchStart = closeRange.upperBound
        }

        return false
    }

    private static func matches(_ raw: String, target: String) -> Bool {
        let destination = raw
            .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? raw
        let withoutHeading = destination
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? destination
        let candidate = normalize(withoutHeading)

        return candidate == target || lastComponent(candidate) == lastComponent(target)
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
    }

    private static func lastComponent(_ value: String) -> String {
        let component = value.split(separator: "/").last.map(String.init) ?? value
        if component.hasSuffix(".markdown") {
            return String(component.dropLast(9))
        }
        return component.hasSuffix(".md") ? String(component.dropLast(3)) : component
    }
}
