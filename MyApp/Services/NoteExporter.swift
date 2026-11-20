import AppKit
import Markdown

private struct ExportInlineStyle {
    var size: CGFloat = 14
    var bold = false
    var italic = false
    var strikethrough = false
    var color: NSColor = .labelColor
    var indent: CGFloat = 0
}

enum NoteExporter {
    static func attributedString(for url: URL) throws -> NSAttributedString {
        let source = try String(contentsOf: url, encoding: .utf8)
        let body = FrontmatterParser.split(source).body
        let document = Document(parsing: body)
        let output = NSMutableAttributedString()
        appendBlocks(
            Array(document.children),
            to: output,
            baseURL: url.deletingLastPathComponent(),
            indent: 0
        )
        return output
    }

    static func richTextPayload(for url: URL) throws -> (rtf: Data, html: Data, plain: String) {
        let attributed = try attributedString(for: url)
        let range = NSRange(location: 0, length: attributed.length)
        let rtf = try attributed.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let html = try attributed.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
        )
        return (rtf, html, attributed.string)
    }

    static func pdfData(for url: URL) throws -> Data {
        let attributed = try attributedString(for: url)
        let pageSize = NSSize(width: 612, height: 792)
        let margin: CGFloat = 54
        let contentWidth = pageSize.width - margin * 2

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 200))
        textView.isRichText = true
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: contentWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textStorage?.setAttributedString(attributed)

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            throw CocoaError(.fileWriteUnknown)
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height
        textView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: max(usedHeight, 1))

        let printInfo = NSPrintInfo()
        printInfo.paperSize = pageSize
        printInfo.topMargin = margin
        printInfo.bottomMargin = margin
        printInfo.leftMargin = margin
        printInfo.rightMargin = margin
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false

        let data = NSMutableData()
        let operation = NSPrintOperation.pdfOperation(
            with: textView,
            inside: textView.bounds,
            to: data
        )
        operation.printInfo = printInfo
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data as Data
    }

    // MARK: - Blocks

    private static func appendBlocks(
        _ markups: [Markup],
        to output: NSMutableAttributedString,
        baseURL: URL,
        indent: CGFloat
    ) {
        for markup in markups {
            switch markup {
            case let heading as Heading:
                var style = ExportInlineStyle(
                    size: headingSize(heading.level),
                    bold: true,
                    indent: indent
                )
                style.color = .labelColor
                output.append(inlineText(Array(heading.children), baseURL: baseURL, style: style))
                output.append(newlines(2, style: style))

            case let paragraph as Paragraph:
                let children = Array(paragraph.children)
                if children.count == 1,
                   let image = children.first as? Markdown.Image,
                   let attachment = attachment(for: image, baseURL: baseURL) {
                    output.append(NSAttributedString(attachment: attachment))
                    output.append(newlines(2, style: ExportInlineStyle(indent: indent)))
                } else {
                    let style = ExportInlineStyle(indent: indent)
                    output.append(inlineText(children, baseURL: baseURL, style: style))
                    output.append(newlines(2, style: style))
                }

            case let codeBlock as CodeBlock:
                let code = codeBlock.code.hasSuffix("\n")
                    ? String(codeBlock.code.dropLast())
                    : codeBlock.code
                var attributes = attributes(for: ExportInlineStyle(indent: indent + 8))
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                attributes[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.1)
                output.append(NSAttributedString(string: code + "\n\n", attributes: attributes))

            case let quote as BlockQuote:
                let buffer = NSMutableAttributedString()
                appendBlocks(Array(quote.children), to: buffer, baseURL: baseURL, indent: indent + 18)
                buffer.addAttribute(
                    .foregroundColor,
                    value: NSColor.secondaryLabelColor,
                    range: NSRange(location: 0, length: buffer.length)
                )
                output.append(buffer)

            case let list as UnorderedList:
                appendList(
                    Array(list.listItems),
                    ordered: false,
                    start: 1,
                    to: output,
                    baseURL: baseURL,
                    indent: indent
                )

            case let list as OrderedList:
                appendList(
                    Array(list.listItems),
                    ordered: true,
                    start: Int(list.startIndex),
                    to: output,
                    baseURL: baseURL,
                    indent: indent
                )

            case let table as Markdown.Table:
                appendTable(table, to: output, baseURL: baseURL, indent: indent)

            case is ThematicBreak:
                let style = ExportInlineStyle(color: .secondaryLabelColor, indent: indent)
                output.append(NSAttributedString(string: "────────────\n\n", attributes: attributes(for: style)))

            case let html as HTMLBlock:
                let style = ExportInlineStyle(
                    size: 12,
                    color: .secondaryLabelColor,
                    indent: indent
                )
                var attributes = attributes(for: style)
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                output.append(NSAttributedString(string: html.rawHTML + "\n\n", attributes: attributes))

            default:
                break
            }
        }
    }

    private static func appendList(
        _ items: [ListItem],
        ordered: Bool,
        start: Int,
        to output: NSMutableAttributedString,
        baseURL: URL,
        indent: CGFloat
    ) {
        for (offset, item) in items.enumerated() {
            let buffer = NSMutableAttributedString()
            appendBlocks(Array(item.children), to: buffer, baseURL: baseURL, indent: indent + 18)
            trimTrailingNewlines(buffer)
            buffer.append(NSAttributedString(string: "\n", attributes: attributes(for: ExportInlineStyle(indent: indent))))

            let marker = ordered ? "\(start + offset)." : "•"
            let markerText = NSAttributedString(
                string: marker + "\t",
                attributes: attributes(for: ExportInlineStyle(color: .secondaryLabelColor, indent: indent))
            )
            buffer.insert(markerText, at: 0)
            output.append(buffer)
        }
        output.append(NSAttributedString(string: "\n"))
    }

    private static func appendTable(
        _ table: Markdown.Table,
        to output: NSMutableAttributedString,
        baseURL: URL,
        indent: CGFloat
    ) {
        func rowText(_ cells: [Markdown.Table.Cell], bold: Bool) -> String {
            cells.map { cell in
                inlineText(
                    Array(cell.children),
                    baseURL: baseURL,
                    style: ExportInlineStyle(size: 12.5, bold: bold, indent: indent)
                ).string
            }
            .joined(separator: "   ")
        }

        let header = rowText(Array(table.head.cells), bold: true)
        output.append(NSAttributedString(string: header + "\n", attributes: attributes(for: ExportInlineStyle(indent: indent))))
        output.append(NSAttributedString(string: "────────────────────────────\n", attributes: attributes(for: ExportInlineStyle(color: .secondaryLabelColor, indent: indent))))
        for row in table.body.rows {
            output.append(NSAttributedString(string: rowText(Array(row.cells), bold: false) + "\n", attributes: attributes(for: ExportInlineStyle(indent: indent))))
        }
        output.append(NSAttributedString(string: "\n"))
    }

    // MARK: - Inlines

    private static func inlineText(
        _ markups: [Markup],
        baseURL: URL,
        style: ExportInlineStyle
    ) -> NSMutableAttributedString {
        let output = NSMutableAttributedString()

        for markup in markups {
            switch markup {
            case let text as Markdown.Text:
                output.append(NSAttributedString(string: text.string, attributes: attributes(for: style)))

            case let strong as Strong:
                var nested = style
                nested.bold = true
                output.append(inlineText(Array(strong.children), baseURL: baseURL, style: nested))

            case let emphasis as Emphasis:
                var nested = style
                nested.italic = true
                output.append(inlineText(Array(emphasis.children), baseURL: baseURL, style: nested))

            case let strike as Strikethrough:
                var nested = style
                nested.strikethrough = true
                output.append(inlineText(Array(strike.children), baseURL: baseURL, style: nested))

            case let code as InlineCode:
                var attributes = attributes(for: style)
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
                attributes[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.12)
                output.append(NSAttributedString(string: " \(code.code) ", attributes: attributes))

            case let link as Markdown.Link:
                let start = output.length
                output.append(inlineText(Array(link.children), baseURL: baseURL, style: style))
                if let destination = link.destination, let url = URL(string: destination) {
                    let range = NSRange(location: start, length: output.length - start)
                    output.addAttributes([.link: url, .foregroundColor: NSColor.linkColor], range: range)
                }

            case let image as Markdown.Image:
                if let attachment = attachment(for: image, baseURL: baseURL) {
                    output.append(NSAttributedString(attachment: attachment))
                } else {
                    output.append(NSAttributedString(string: image.plainText, attributes: attributes(for: style)))
                }

            case is SoftBreak:
                output.append(NSAttributedString(string: " ", attributes: attributes(for: style)))

            case is LineBreak:
                output.append(NSAttributedString(string: "\n", attributes: attributes(for: style)))

            case let html as InlineHTML:
                var attributes = attributes(for: style)
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
                output.append(NSAttributedString(string: html.rawHTML, attributes: attributes))

            default:
                let fallback = markup.format()
                if !fallback.isEmpty {
                    output.append(NSAttributedString(string: fallback, attributes: attributes(for: style)))
                }
            }
        }

        return output
    }

    // MARK: - Helpers

    private static func attributes(for style: ExportInlineStyle) -> [NSAttributedString.Key: Any] {
        var font = NSFont.systemFont(ofSize: style.size)
        if style.bold {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if style.italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 4
        paragraph.headIndent = style.indent
        paragraph.firstLineHeadIndent = style.indent

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.color,
            .paragraphStyle: paragraph
        ]
        if style.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    private static func newlines(_ count: Int, style: ExportInlineStyle) -> NSAttributedString {
        NSAttributedString(string: String(repeating: "\n", count: count), attributes: attributes(for: style))
    }

    private static func trimTrailingNewlines(_ string: NSMutableAttributedString) {
        while string.length > 0,
              (string.string as NSString).character(at: string.length - 1) == 10 {
            string.deleteCharacters(in: NSRange(location: string.length - 1, length: 1))
        }
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 26
        case 2: 21
        case 3: 17.5
        case 4: 15.5
        case 5: 14.5
        default: 13.5
        }
    }

    private static func attachment(for image: Markdown.Image, baseURL: URL) -> NSTextAttachment? {
        guard let source = image.source,
              let url = MediaLibrary.resolveImageURL(source, baseURL: baseURL),
              let loaded = MediaLibrary.thumbnail(at: url, maxPixelSize: 960) else {
            return nil
        }
        var size = loaded.size
        let maxWidth: CGFloat = 480
        if size.width > maxWidth, size.width > 0 {
            size = NSSize(width: maxWidth, height: size.height * maxWidth / size.width)
        }
        let attachment = NSTextAttachment()
        attachment.image = loaded
        attachment.bounds = CGRect(origin: .zero, size: size)
        return attachment
    }
}
