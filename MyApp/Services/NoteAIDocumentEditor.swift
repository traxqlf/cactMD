import Foundation

/// Pure text transforms used by the note assistant.
///
/// They never touch the disk: `WorkspaceStore` owns the write, the cache
/// invalidation and the editor refresh. Keeping the string surgery here makes
/// it testable and keeps the risky YAML merge out of the view.
nonisolated enum NoteAIDocumentEditor {
    /// Hard cap for a single model call. The on-device context window is about
    /// 4k tokens, so a long note is sampled from its beginning instead of
    /// failing with a context error.
    static let sourceLimit = 9_000

    struct ProofreadInput: Sendable {
        let header: String
        let text: String
        let blocks: [String]
        let truncated: Bool
        let hadTrailingNewline: Bool
    }

    struct ProtectedText: Sendable {
        let text: String
        let blocks: [String]
    }

    // MARK: - Frontmatter

    /// Splits the exact YAML block (delimiters included) from the body.
    static func splitFrontmatter(_ source: String) -> (header: String, body: String) {
        guard source.hasPrefix("---\n") || source.hasPrefix("---\r\n") else {
            return ("", source)
        }
        guard let firstLineEnd = source.firstIndex(of: "\n") else { return ("", source) }
        var cursor = source.index(after: firstLineEnd)

        while cursor < source.endIndex {
            let lineEnd = source[cursor...].firstIndex(of: "\n") ?? source.endIndex
            let line = String(source[cursor..<lineEnd]).trimmingCharacters(in: .whitespaces)
            let next = lineEnd < source.endIndex ? source.index(after: lineEnd) : source.endIndex
            if line == "---" || line == "..." {
                return (String(source[..<next]), String(source[next...]))
            }
            cursor = next
        }
        // No closing delimiter: not frontmatter, never swallow the whole note.
        return ("", source)
    }

    static func newline(in source: String) -> String {
        source.contains("\r\n") ? "\r\n" : "\n"
    }

    // MARK: - Summary

    /// Inserts the generated Obsidian callout right after the YAML block.
    /// An existing summary callout at the top of the body is replaced, so
    /// clicking twice cannot stack two summaries.
    static func insertingSummary(_ rawCallout: String, into source: String) -> String {
        let nl = newline(in: source)
        var callout = strippingWrapper(rawCallout)
        guard !callout.isEmpty else { return source }
        callout = callout
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: nl)

        let (rawHeader, rawBody) = splitFrontmatter(source)
        var header = rawHeader
        if !header.isEmpty, !header.hasSuffix("\n") { header += nl }

        var body = rawBody
        let lines = body.components(separatedBy: nl)
        var start = 0
        while start < lines.count,
              lines[start].trimmingCharacters(in: .whitespaces).isEmpty {
            start += 1
        }
        if start < lines.count,
           lines[start].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("> [!summary]") {
            var end = start
            while end < lines.count,
                  lines[end].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                end += 1
            }
            if end < lines.count,
               lines[end].trimmingCharacters(in: .whitespaces).isEmpty {
                end += 1
            }
            var remaining = lines
            remaining.removeSubrange(start..<end)
            body = remaining.joined(separator: nl)
        }

        return header + callout + nl + nl + body
    }

    // MARK: - YAML properties

    /// Merges `resume`, `categorie` and `tags` without overwriting existing
    /// keys. Existing tags are kept and generated tags are appended.
    static func mergingMetadata(_ metadata: NoteAIMetadata, into source: String) -> String {
        let nl = newline(in: source)
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let (header, body) = splitFrontmatter(normalized)
        let generatedTags = normalizedTags(metadata.tags)
        let summary = metadata.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = metadata.category.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !generatedTags.isEmpty || !summary.isEmpty || !category.isEmpty else {
            return source
        }

        guard let lines = frontmatterLines(from: header) else {
            var block = ["---"]
            if !summary.isEmpty { block.append("resume: \(yamlScalar(summary))") }
            if !category.isEmpty { block.append("categorie: \(yamlScalar(category))") }
            if !generatedTags.isEmpty {
                block.append("tags:")
                block.append(contentsOf: generatedTags.map { "  - \(yamlTagScalar($0))" })
            }
            block.append("---")
            let prefix = block.joined(separator: "\n") + "\n"
            return restoreNewlines(prefix + normalized, nl)
        }

        let closing = lines.last ?? "---"
        var inner = Array(lines[1..<(lines.count - 1)])
        let existingKeys = Set(inner.compactMap { topLevelKey($0)?.lowercased() })

        var existingTags: [String] = []
        var tagRange: Range<Int>?
        var tagsAreComplex = false

        for (index, line) in inner.enumerated() {
            guard topLevelKey(line)?.caseInsensitiveCompare("tags") == .orderedSame else { continue }
            let inlineValue = line
                .drop(while: { $0 != ":" })
                .dropFirst()
                .trimmingCharacters(in: .whitespaces)
            var parsed = parseTagValue(String(inlineValue))
            var end = index + 1

            while end < inner.count {
                let trimmed = inner[end].trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { break }
                if trimmed.hasPrefix("- ") || trimmed == "-" {
                    let tag = cleanTagValue(String(trimmed.dropFirst()))
                    if !tag.isEmpty { parsed.append(tag) }
                    end += 1
                } else if inner[end].first == " " || inner[end].first == "\t" {
                    // A nested mapping under `tags`: leave it untouched rather
                    // than replacing a structure this editor cannot model.
                    tagsAreComplex = true
                    break
                } else {
                    break
                }
            }

            if tagsAreComplex { break }
            existingTags = parsed
            tagRange = index..<end
            break
        }

        if !generatedTags.isEmpty, !tagsAreComplex {
            var merged = existingTags
            var seen = Set(merged.map { $0.lowercased() })
            for tag in generatedTags where seen.insert(tag.lowercased()).inserted {
                merged.append(tag)
            }

            let tagLines = merged.isEmpty
                ? []
                : ["tags:"] + merged.map { "  - \(yamlTagScalar($0))" }

            if let tagRange {
                inner.replaceSubrange(tagRange, with: tagLines)
            } else {
                inner.append(contentsOf: tagLines)
            }
        }

        if !summary.isEmpty, !existingKeys.contains("resume") {
            inner.append("resume: \(yamlScalar(summary))")
        }
        if !category.isEmpty, !existingKeys.contains("categorie") {
            inner.append("categorie: \(yamlScalar(category))")
        }

        let rebuilt = (["---"] + inner + [closing]).joined(separator: "\n") + "\n"
        return restoreNewlines(rebuilt + body, nl)
    }

    // MARK: - Proofreading

    /// Removes the frontmatter and fences code blocks so the model cannot
    /// rewrite either. The exact header and the code blocks are restored when
    /// the result is applied.
    static func preparedForProofread(source: String) -> ProofreadInput {
        let (header, body) = splitFrontmatter(source)
        let sampled = truncated(body, limit: sourceLimit)
        let protectedCode = protectingCodeBlocks(in: sampled.text)
        let protected = protectingCallouts(in: protectedCode.text, blocks: protectedCode.blocks)
        return ProofreadInput(
            header: header,
            text: protected.text,
            blocks: protected.blocks,
            truncated: sampled.truncated,
            hadTrailingNewline: body.hasSuffix("\n")
        )
    }

    static func restoringProofread(_ raw: String, input: ProofreadInput) -> String? {
        guard !input.truncated else { return nil }
        let cleaned = strippingWrapper(raw)
        guard let body = restoringCodeBlocks(in: cleaned, blocks: input.blocks) else { return nil }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let nl = newline(in: input.header)
        var restored = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: nl)
        if input.hadTrailingNewline, !restored.hasSuffix(nl) {
            restored += nl
        }

        var header = input.header
        if !header.isEmpty, !header.hasSuffix("\n") { header += nl }
        return header + restored
    }

    // MARK: - Model input

    /// Body-only sample for summary, questions and metadata. The YAML block is
    /// already displayed in the app and would only waste the context window.
    static func modelText(from source: String) -> (text: String, truncated: Bool) {
        let body = splitFrontmatter(source).body
        return truncated(body, limit: sourceLimit)
    }

    /// Shortens at a line boundary so the model never receives a half sentence.
    static func truncated(_ source: String, limit: Int) -> (text: String, truncated: Bool) {
        guard source.count > limit else { return (source, false) }
        let cut = source.index(source.startIndex, offsetBy: limit)
        let prefix = source[..<cut]
        let trimmed = prefix.lastIndex(of: "\n").map { String(prefix[..<$0]) } ?? String(prefix)
        return (trimmed + "\n\n[… note tronquée pour le modèle local …]", true)
    }

    // MARK: - Output clean-up

    /// Strips a wrapper code fence and the `=====` guard lines some models
    /// repeat from the prompt. Never applied to a note body outside an AI
    /// result.
    static func strippingWrapper(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Order matters: a model may put its `=====` guard lines around a
        // fenced block. Peel the guards, then the fence, then guards again.
        text = trimmingGuardLines(text)

        if text.hasPrefix("```") || text.hasPrefix("~~~") {
            var lines = text.components(separatedBy: "\n")
            if let first = lines.first,
               (first.trimmingCharacters(in: .whitespaces).hasPrefix("```")
                || first.trimmingCharacters(in: .whitespaces).hasPrefix("~~~")) {
                lines.removeFirst()
            }
            if let last = lines.last,
               (last.trimmingCharacters(in: .whitespaces).hasPrefix("```")
                || last.trimmingCharacters(in: .whitespaces).hasPrefix("~~~")) {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmingGuardLines(text)
    }

    private static func trimmingGuardLines(_ raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        while let first = lines.first, isGuardLine(first) { lines.removeFirst() }
        while let last = lines.last, isGuardLine(last) { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the exact Obsidian callout even when the model answers with a
    /// plain bullet list.
    static func normalizedSummaryCallout(_ raw: String) -> String {
        let text = strippingWrapper(raw)
        var points: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let lowered = line.lowercased()
            if lowered.hasPrefix("> [!summary]") { continue }
            if line.hasPrefix("#") { continue }
            if lowered == "résumé" || lowered == "**résumé**" { continue }
            if line.hasPrefix(">") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            if !line.isEmpty { points.append(line) }
            if points.count == 5 { break }
        }

        guard !points.isEmpty else { return "" }
        return (["> [!summary] Résumé"] + points.map { "> - \($0)" }).joined(separator: "\n")
    }

    // MARK: - Tags

    /// Lowercase, no `#`, no spaces, no hyphens, deduplicated, 5 maximum.
    static func normalizedTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for item in raw {
            var tag = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            tag = tag.replacingOccurrences(of: "#", with: "")
            tag = tag.replacingOccurrences(of: " ", with: "")
            tag = tag.replacingOccurrences(of: "\t", with: "")
            tag = tag.replacingOccurrences(of: "-", with: "")
            tag = tag.replacingOccurrences(of: "_", with: "")
            tag = String(tag.filter { $0.isLetter || $0.isNumber })
            guard !tag.isEmpty, seen.insert(tag).inserted else { continue }
            result.append(tag)
            if result.count == 5 { break }
        }
        return result
    }

    // MARK: - Code block protection

    static func protectingCodeBlocks(in text: String) -> ProtectedText {
        guard let regex = try? NSRegularExpression(
            pattern: "(?ms)^[ \\t]{0,3}(`{3,}|~{3,}).*?^[ \\t]{0,3}\\1[ \\t]*$"
        ) else {
            return ProtectedText(text: text, blocks: [])
        }

        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return ProtectedText(text: text, blocks: []) }

        var output = ""
        var blocks: [String] = []
        var cursor = text.startIndex

        for (index, match) in matches.enumerated() {
            guard let range = Range(match.range, in: text) else { continue }
            output += text[cursor..<range.lowerBound]
            blocks.append(String(text[range]))
            output += "⟦\(index + 1)⟧"
            cursor = range.upperBound
        }
        output += text[cursor...]
        return ProtectedText(text: output, blocks: blocks)
    }

    static func restoringCodeBlocks(in text: String, blocks: [String]) -> String? {
        guard !blocks.isEmpty else { return text }
        var result = text
        for (index, block) in blocks.enumerated() {
            let token = "⟦\(index + 1)⟧"
            guard result.components(separatedBy: token).count == 2 else { return nil }
            result = result.replacingOccurrences(of: token, with: block)
        }
        return result
    }

    /// Obsidian callouts (`> [!summary]`) are not wikilinks: without this the
    /// model reliably turns them into `[[!summary]]` while proofreading.
    static func protectingCallouts(in text: String, blocks: [String]) -> ProtectedText {
        guard let regex = try? NSRegularExpression(pattern: "\\[![A-Za-z0-9_-]+\\]") else {
            return ProtectedText(text: text, blocks: blocks)
        }

        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return ProtectedText(text: text, blocks: blocks) }

        var output = ""
        var protected = blocks
        var cursor = text.startIndex

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            output += text[cursor..<range.lowerBound]
            protected.append(String(text[range]))
            output += "⟦\(protected.count)⟧"
            cursor = range.upperBound
        }
        output += text[cursor...]
        return ProtectedText(text: output, blocks: protected)
    }

    // MARK: - Private helpers

    private static func frontmatterLines(from header: String) -> [String]? {
        guard !header.isEmpty else { return nil }
        var lines = header
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count >= 2,
              lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.lastIndex(where: {
                  let trimmed = $0.trimmingCharacters(in: .whitespaces)
                  return trimmed == "---" || trimmed == "..."
              }),
              close > 0 else {
            return nil
        }
        return lines
    }

    private static func topLevelKey(_ line: String) -> String? {
        guard let first = line.first, first != " ", first != "\t", first != "-", first != "#" else {
            return nil
        }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : String(key)
    }

    private static func parseTagValue(_ raw: String) -> [String] {
        var value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return [] }
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        return value
            .split(separator: ",")
            .map { cleanTagValue(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func cleanTagValue(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: "#", with: "")
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func yamlScalar(_ value: String) -> String {
        let flattened = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(flattened)\""
    }

    private static func yamlTagScalar(_ value: String) -> String {
        let safe = !value.isEmpty && value.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "."
        }
        return safe ? value : yamlScalar(value)
    }

    private static func restoreNewlines(_ text: String, _ newline: String) -> String {
        newline == "\r\n" ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
    }

    private static func isGuardLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3 && trimmed.allSatisfy { $0 == "=" }
    }

    // MARK: - Debug self-check

    #if DEBUG
    /// Runs once when the assistant first opens. Cheap, and it catches a YAML
    /// editor regression before it can reach a real note.
    static func selfCheck() {
        let note = """
        ---
        title: Test
        tags: [alpha, beta]
        ---
        # Titre

        ```swift
        print(1)
        ```
        """
        let metadata = NoteAIMetadata(
            summary: "Un résumé",
            category: "Test",
            tags: ["gamma", "alpha"]
        )
        let merged = mergingMetadata(metadata, into: note)
        assert(merged.contains("title: Test"))
        assert(merged.contains("  - alpha"))
        assert(merged.contains("  - beta"))
        assert(merged.contains("  - gamma"))
        assert(!merged.contains("tags: [alpha, beta]"))
        assert(merged.contains("resume: \"Un résumé\""))
        assert(merged.contains("categorie: \"Test\""))

        let inserted = insertingSummary("> [!summary] Résumé\n> - Point clé", into: note)
        assert(inserted.contains("---\n> [!summary] Résumé"))
        assert(inserted.hasSuffix("# Titre\n\n```swift\nprint(1)\n```"))

        let protected = protectingCodeBlocks(in: "A\n```swift\nprint(1)\n```\nB")
        assert(protected.blocks.count == 1)
        assert(restoringCodeBlocks(in: protected.text, blocks: protected.blocks)
            == "A\n```swift\nprint(1)\n```\nB")

        let calloutInput = preparedForProofread(source: "> [!summary] Résumé\n> - Point\n\nTexte")
        assert(calloutInput.blocks == ["[!summary]"])
        assert(!calloutInput.text.contains("[!summary]"))
        let repaired = restoringProofread(
            calloutInput.text.replacingOccurrences(of: "Texte", with: "Textes"),
            input: calloutInput
        )
        assert(repaired == "> [!summary] Résumé\n> - Point\n\nTextes", "got: \(repaired ?? "nil")")

        let callout = normalizedSummaryCallout("""
        ```markdown
        ====
        > [!summary] Résumé
        > - Un
        > - Deux
        ====
        ```
        """)
        assert(callout == "> [!summary] Résumé\n> - Un\n> - Deux")
        assert(normalizedTags(["#Machine Learning", "macOS", "macos"]) == ["machinelearning", "macos"])
    }
    #endif
}
