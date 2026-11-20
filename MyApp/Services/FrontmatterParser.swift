import Foundation

nonisolated enum FrontmatterParser {
    /// Splits a leading YAML block from the Markdown body. Only flat `key: value`
    /// pairs and `- item` lists are interpreted; nested mappings stay as text.
    static func split(_ source: String) -> (fields: [FrontmatterField], body: String) {
        var normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.hasPrefix("\u{FEFF}") {
            normalized.removeFirst()
        }
        guard normalized.hasPrefix("---\n") else { return ([], normalized) }

        let remainder = normalized.dropFirst(4)
        let lines = remainder.components(separatedBy: "\n")
        guard let closing = lines.firstIndex(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed == "---" || trimmed == "..."
        }) else {
            return ([], normalized)
        }

        let fields = parseFields(Array(lines[..<closing]))
        let body = lines[(closing + 1)...].joined(separator: "\n")
        return (fields, body)
    }

    static func fields(in source: String) -> [FrontmatterField] {
        split(source).fields
    }

    private static func parseFields(_ lines: [String]) -> [FrontmatterField] {
        var fields: [FrontmatterField] = []

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            if trimmed.hasPrefix("-"), var last = fields.popLast() {
                let item = displayValue(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                guard !item.isEmpty else {
                    fields.append(last)
                    continue
                }
                last = FrontmatterField(
                    id: last.id,
                    key: last.key,
                    value: last.value.isEmpty ? item : "\(last.value), \(item)"
                )
                fields.append(last)
                continue
            }

            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let value = String(trimmed[trimmed.index(after: separator)...])
            fields.append(
                FrontmatterField(
                    id: fields.count,
                    key: key,
                    value: displayValue(value.trimmingCharacters(in: .whitespaces))
                )
            )
        }

        return fields
    }

    private static func displayValue(_ raw: String) -> String {
        var value = raw
        if value.hasPrefix("["), value.hasSuffix("]") {
            let inner = String(value.dropFirst().dropLast())
            return inner
                .split(separator: ",")
                .map { displayValue(String($0).trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
}
