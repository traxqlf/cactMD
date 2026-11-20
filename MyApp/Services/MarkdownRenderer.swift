import Foundation
import Markdown
import SwiftUI

nonisolated enum MarkdownRenderer {
    #if DEBUG
    /// Unbuffered: `print` is block-buffered when stdout is a pipe.
    private static func debugLog(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
    #endif

    /// Reads and parses a note. Always called off the main actor (the store
    /// owns it inside a detached task) and cancellation-aware, so clicking
    /// another note abandons the previous parse instead of finishing it.
    ///
    /// Word count, outline and tags are deliberately *not* computed here: they
    /// are secondary metadata the store measures after the text is on screen.
    static func loadNote(at url: URL) async throws -> RenderedNote {
        try Task.checkCancellation()
        #if DEBUG
        let loadStart = CFAbsoluteTimeGetCurrent()
        #endif
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        try Task.checkCancellation()
        let source = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let (frontmatter, body) = FrontmatterParser.split(source)
        let baseURL = url.deletingLastPathComponent()

        #if DEBUG
        let afterRead = CFAbsoluteTimeGetCurrent()
        #endif
        let document = Document(parsing: body)
        #if DEBUG
        let afterCMark = CFAbsoluteTimeGetCurrent()
        #endif
        var nextID = 0
        let blocks = try convertBlocks(Array(document.children), nextID: &nextID, baseURL: baseURL)
        #if DEBUG
        debugLog(String(
            format: "[systemMD] parse: read %.1f ms, cmark %.1f ms, blocks %.1f ms",
            (afterRead - loadStart) * 1000,
            (afterCMark - afterRead) * 1000,
            (CFAbsoluteTimeGetCurrent() - afterCMark) * 1000
        ))
        #endif
        return RenderedNote(
            note: LoadedNote(
                url: url,
                modificationDate: values?.contentModificationDate,
                byteCount: data.count,
                blocks: blocks,
                headings: [],
                frontmatter: frontmatter,
                tags: [],
                wordCount: 0,
                characterCount: 0
            ),
            text: source
        )
    }

    /// First paint for a large note that is not in the cache: read a prefix of
    /// the file, parse just that prefix and hand back the first blocks. The
    /// whole document is parsed separately, in the background, so a cold open
    /// shows text in a few milliseconds instead of waiting for `cmark` on a
    /// 250 KB changelog.
    static func loadPreview(at url: URL, maxBlocks: Int, maxBytes: Int) async throws -> LoadedNote {
        try Task.checkCancellation()
        #if DEBUG
        let start = CFAbsoluteTimeGetCurrent()
        #endif

        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        var source = String(data: data, encoding: .utf8) ?? ""
        // Never end the prefix in the middle of a line: a cut inside a table
        // delimiter or a fenced block would produce garbage blocks.
        if let lastNewline = source.lastIndex(of: "\n") {
            source = String(source[..<lastNewline])
        }

        let (frontmatter, body) = FrontmatterParser.split(source)
        let document = Document(parsing: body)
        var nextID = 0
        let blocks = try convertBlocks(
            Array(document.children),
            nextID: &nextID,
            baseURL: url.deletingLastPathComponent(),
            limit: maxBlocks
        )

        #if DEBUG
        debugLog(String(
            format: "[systemMD] preview %@ in %.1f ms (%d blocks, %d KB prefix)",
            url.lastPathComponent,
            (CFAbsoluteTimeGetCurrent() - start) * 1000,
            blocks.count,
            data.count / 1024
        ))
        #endif

        return LoadedNote(
            url: url,
            modificationDate: values?.contentModificationDate,
            byteCount: values?.fileSize ?? data.count,
            blocks: blocks,
            headings: [],
            frontmatter: frontmatter,
            tags: [],
            wordCount: 0,
            characterCount: 0
        )
    }

    private static func convertBlocks(
        _ markups: [Markup],
        nextID: inout Int,
        baseURL: URL,
        limit: Int = .max
    ) throws -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        result.reserveCapacity(min(markups.count, limit))

        for markup in markups {
            guard result.count < limit else { break }
            try Task.checkCancellation()
            let id = nextID
            nextID += 1

            switch markup {
            case let heading as Heading:
                let runs = inlineRuns(Array(heading.children), allowTags: false)
                let size = headingSize(heading.level)
                let text = LazyAttributed(
                    plainText: plainText(of: runs),
                    content: .runs(runs, size: size, weight: .semibold)
                )
                result.append(MarkdownBlock(id: id, kind: .heading(level: heading.level, text: text)))

            case let paragraph as Paragraph:
                let children = Array(paragraph.children)
                if children.count == 1,
                   let image = children.first as? Markdown.Image,
                   let source = image.source,
                   let imageURL = MediaLibrary.resolveImageURL(source, baseURL: baseURL) {
                    let alt = image.plainText.isEmpty
                        ? imageURL.deletingPathExtension().lastPathComponent
                        : image.plainText
                    result.append(MarkdownBlock(id: id, kind: .image(url: imageURL, alt: alt)))
                } else {
                    let runs = inlineRuns(children)
                    let text = LazyAttributed(
                        plainText: plainText(of: runs),
                        content: .runs(runs, size: 15, weight: .regular)
                    )
                    result.append(MarkdownBlock(id: id, kind: .paragraph(text: text)))
                }

            case let codeBlock as CodeBlock:
                let trimmed = codeBlock.code.hasSuffix("\n")
                    ? String(codeBlock.code.dropLast())
                    : codeBlock.code
                let language = codeBlock.language
                let highlighted = LazyAttributed(
                    plainText: trimmed,
                    content: .code(trimmed, language: language)
                )
                result.append(
                    MarkdownBlock(
                        id: id,
                        kind: .codeBlock(language: codeBlock.language, code: trimmed, highlighted: highlighted)
                    )
                )

            case let quote as BlockQuote:
                let nested = try convertBlocks(Array(quote.children), nextID: &nextID, baseURL: baseURL)
                result.append(MarkdownBlock(id: id, kind: .blockQuote(blocks: nested)))

            case let list as UnorderedList:
                let items = try convertListItems(list.listItems, nextID: &nextID, baseURL: baseURL)
                result.append(MarkdownBlock(id: id, kind: .list(ordered: false, startIndex: 1, items: items)))

            case let list as OrderedList:
                let items = try convertListItems(list.listItems, nextID: &nextID, baseURL: baseURL)
                result.append(
                    MarkdownBlock(
                        id: id,
                        kind: .list(ordered: true, startIndex: Int(list.startIndex), items: items)
                    )
                )

            case let table as Markdown.Table:
                let alignments: [MarkdownTableAlignment] = table.columnAlignments.map { alignment in
                    switch alignment {
                    case .center: .center
                    case .right: .right
                    case .left, .none: .left
                    }
                }
                let headers = Array(table.head.cells.map { styledCell($0, weight: .semibold) })
                let rows = Array(table.body.rows.map { row in
                    Array(row.cells.map { styledCell($0, weight: .regular) })
                })
                result.append(MarkdownBlock(id: id, kind: .table(alignments: alignments, headers: headers, rows: rows)))

            case is ThematicBreak:
                result.append(MarkdownBlock(id: id, kind: .thematicBreak))

            case let html as HTMLBlock:
                let raw = html.rawHTML.trimmingCharacters(in: .newlines)
                let text = LazyAttributed(
                    plainText: raw,
                    content: .runs([MarkdownInline(raw, kind: .html)], size: 13, weight: .regular)
                )
                result.append(MarkdownBlock(id: id, kind: .paragraph(text: text)))

            default:
                break
            }
        }

        return result
    }

    private static func convertListItems(
        _ listItems: LazyMapSequence<MarkupChildren, ListItem>,
        nextID: inout Int,
        baseURL: URL
    ) throws -> [MarkdownListItem] {
        try listItems.map { item in
            try Task.checkCancellation()
            let itemID = nextID
            nextID += 1
            let checked: Bool? = switch item.checkbox {
            case .checked: true
            case .unchecked: false
            case .none: nil
            }
            let blocks = try convertBlocks(Array(item.children), nextID: &nextID, baseURL: baseURL)
            return MarkdownListItem(
                id: itemID,
                checkbox: checked,
                sourceLine: item.range?.lowerBound.line,
                blocks: blocks
            )
        }
    }

    private static func plainText(of runs: [MarkdownInline]) -> String {
        runs.count == 1 ? (runs.first?.text ?? "") : runs.map(\.text).joined()
    }

    private static func styledCell(_ cell: Markdown.Table.Cell, weight: MarkdownTextWeight) -> LazyAttributed {
        let runs = inlineRuns(Array(cell.children))
        return LazyAttributed(
            plainText: plainText(of: runs),
            content: .runs(runs, size: 13.5, weight: weight)
        )
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 28
        case 2: 22
        case 3: 18
        case 4: 16
        case 5: 14.5
        default: 13.5
        }
    }

    /// Inline content as runs: no font, colour or attribute graph is built
    /// here, so parsing a long note stays cheap. `MarkdownTextStyler` turns a
    /// block's runs into an `AttributedString` the first time it is painted.
    private static func inlineRuns(
        _ markups: [Markup],
        isBold: Bool = false,
        isItalic: Bool = false,
        isStrikethrough: Bool = false,
        allowTags: Bool = true
    ) -> [MarkdownInline] {
        var output: [MarkdownInline] = []

        for markup in markups {
            switch markup {
            case let text as Markdown.Text:
                appendTextRuns(
                    text.string,
                    bold: isBold,
                    italic: isItalic,
                    strikethrough: isStrikethrough,
                    allowTags: allowTags,
                    into: &output
                )

            case let strong as Strong:
                output += inlineRuns(
                    Array(strong.children),
                    isBold: true,
                    isItalic: isItalic,
                    isStrikethrough: isStrikethrough,
                    allowTags: allowTags
                )

            case let emphasis as Emphasis:
                output += inlineRuns(
                    Array(emphasis.children),
                    isBold: isBold,
                    isItalic: true,
                    isStrikethrough: isStrikethrough,
                    allowTags: allowTags
                )

            case let strike as Strikethrough:
                output += inlineRuns(
                    Array(strike.children),
                    isBold: isBold,
                    isItalic: isItalic,
                    isStrikethrough: true,
                    allowTags: allowTags
                )

            case let code as InlineCode:
                output.append(MarkdownInline(code.code, kind: .code))

            case let link as Markdown.Link:
                var runs = inlineRuns(
                    Array(link.children),
                    isBold: isBold,
                    isItalic: isItalic,
                    isStrikethrough: isStrikethrough
                )
                if let destination = link.destination, let url = URL(string: destination) {
                    for index in runs.indices where runs[index].kind == .text {
                        runs[index].kind = .link
                        runs[index].destination = url
                    }
                }
                output += runs

            case let image as Markdown.Image:
                let alt = image.plainText.isEmpty ? (image.source ?? "image") : image.plainText
                output.append(MarkdownInline(alt, kind: .image, bold: isBold, italic: true))

            case is SoftBreak:
                output.append(MarkdownInline(" "))

            case is LineBreak:
                output.append(MarkdownInline("\n"))

            case let html as InlineHTML:
                output.append(MarkdownInline(html.rawHTML, kind: .html))

            default:
                let fallback = markup.format()
                if !fallback.isEmpty {
                    output.append(MarkdownInline(fallback, bold: isBold, italic: isItalic))
                }
            }
        }

        return output
    }

    private static let wikilinkRegex = try? NSRegularExpression(
        pattern: #"\[\[([^\[\]|]+)(?:\|([^\[\]]+))?\]\]"#
    )

    private static let tagRegex = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_/])#(\p{L}[\p{L}\p{N}_/-]*)"#
    )

    private static func appendTextRuns(
        _ text: String,
        bold: Bool,
        italic: Bool,
        strikethrough: Bool,
        allowTags: Bool,
        into output: inout [MarkdownInline]
    ) {
        guard let regex = wikilinkRegex, text.contains("[[") else {
            appendTagRuns(
                text,
                bold: bold,
                italic: italic,
                strikethrough: strikethrough,
                allowTags: allowTags,
                into: &output
            )
            return
        }

        let nsText = text as NSString
        var location = 0
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            if match.range.location > location {
                appendTagRuns(
                    nsText.substring(
                        with: NSRange(location: location, length: match.range.location - location)
                    ),
                    bold: bold,
                    italic: italic,
                    strikethrough: strikethrough,
                    allowTags: allowTags,
                    into: &output
                )
            }

            let target = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let aliasRange = match.range(at: 2)
            let display = aliasRange.location == NSNotFound
                ? target
                : nsText.substring(with: aliasRange)

            if let url = wikilinkURL(target: target) {
                output.append(
                    MarkdownInline(
                        display,
                        kind: .wikilink,
                        bold: bold,
                        italic: italic,
                        destination: url
                    )
                )
            } else {
                appendTagRuns(
                    display,
                    bold: bold,
                    italic: italic,
                    strikethrough: strikethrough,
                    allowTags: allowTags,
                    into: &output
                )
            }

            location = match.range.location + match.range.length
        }

        if location < nsText.length {
            appendTagRuns(
                nsText.substring(from: location),
                bold: bold,
                italic: italic,
                strikethrough: strikethrough,
                allowTags: allowTags,
                into: &output
            )
        }
    }

    private static func appendTagRuns(
        _ text: String,
        bold: Bool,
        italic: Bool,
        strikethrough: Bool,
        allowTags: Bool,
        into output: inout [MarkdownInline]
    ) {
        guard allowTags, let regex = tagRegex, text.contains("#") else {
            if !text.isEmpty {
                output.append(
                    MarkdownInline(
                        text,
                        bold: bold,
                        italic: italic,
                        strikethrough: strikethrough
                    )
                )
            }
            return
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var cursor = 0

        for match in matches {
            if match.range.location > cursor {
                output.append(
                    MarkdownInline(
                        nsText.substring(
                            with: NSRange(location: cursor, length: match.range.location - cursor)
                        ),
                        bold: bold,
                        italic: italic,
                        strikethrough: strikethrough
                    )
                )
            }

            let tag = nsText.substring(with: match.range(at: 1))
            output.append(
                MarkdownInline(
                    tag,
                    kind: .tag,
                    bold: bold,
                    italic: italic,
                    destination: tagURL(tag)
                )
            )

            cursor = match.range.location + match.range.length
        }

        if cursor < nsText.length {
            output.append(
                MarkdownInline(
                    nsText.substring(from: cursor),
                    bold: bold,
                    italic: italic,
                    strikethrough: strikethrough
                )
            )
        }
    }

    static func wikilinkURL(target: String) -> URL? {
        var components = URLComponents()
        components.scheme = "systemmd"
        components.host = "wikilink"
        components.queryItems = [URLQueryItem(name: "name", value: target)]
        return components.url
    }

    static func tagURL(_ tag: String) -> URL? {
        var components = URLComponents()
        components.scheme = "systemmd"
        components.host = "tag"
        components.queryItems = [URLQueryItem(name: "name", value: tag)]
        return components.url
    }

    /// Outline extraction runs in the background, like the other secondary
    /// metadata: the reader is already painted when this walks the blocks.
    static func headings(in blocks: [MarkdownBlock]) -> [NoteHeading] {
        collectHeadings(from: blocks)
    }

    private static func collectHeadings(from blocks: [MarkdownBlock]) -> [NoteHeading] {
        var headings: [NoteHeading] = []

        func walk(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                switch block.kind {
                case .heading(let level, let text):
                    if level <= 3 {
                        headings.append(
                            NoteHeading(id: block.id, level: level, title: text.plainText)
                        )
                    }
                case .blockQuote(let nested):
                    walk(nested)
                case .list(_, _, let items):
                    for item in items {
                        walk(item.blocks)
                    }
                default:
                    break
                }
            }
        }

        walk(blocks)
        return headings
    }

    private static let checkboxRegex = try? NSRegularExpression(pattern: #"\[( |x|X)\]"#)

    static func toggleTaskCheckbox(at url: URL, line: Int) throws {
        let source = try String(contentsOf: url, encoding: .utf8)
        var lines = source.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return }

        let index = line - 1
        let nsLine = lines[index] as NSString
        guard let regex = checkboxRegex,
              let match = regex.firstMatch(
                in: lines[index],
                range: NSRange(location: 0, length: nsLine.length)
              ) else {
            return
        }

        let token = nsLine.substring(with: match.range)
        let replacement = token.lowercased() == "[x]" ? "[ ]" : "[x]"
        let mutable = NSMutableString(string: lines[index])
        mutable.replaceCharacters(in: match.range, with: replacement)
        lines[index] = mutable as String

        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

}
