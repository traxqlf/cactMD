import AppKit
import SwiftUI

/// Turns the parser's inline runs into the `NSAttributedString` the reader's
/// `NSTextView` renders. This is the only place that knows about fonts,
/// colours and link decorations, so the parser stays a pure text pass and the
/// reader pays for styling only when a block is painted.
nonisolated enum MarkdownTextStyler {
    // MARK: - Fonts

    static func font(
        size: CGFloat,
        weight: MarkdownTextWeight,
        bold: Bool = false,
        italic: Bool = false
    ) -> NSFont {
        let baseWeight: NSFont.Weight = weight == .semibold ? .semibold : .regular
        let base = NSFont.systemFont(ofSize: size, weight: baseWeight)
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        guard !traits.isEmpty else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: traits)
    }

    static func paragraphStyle(
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat = 0,
        paragraphSpacingBefore: CGFloat = 0,
        headIndent: CGFloat = 0,
        firstLineHeadIndent: CGFloat = 0
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = paragraphSpacing
        style.paragraphSpacingBefore = paragraphSpacingBefore
        style.headIndent = headIndent
        style.firstLineHeadIndent = firstLineHeadIndent
        return style
    }

    // MARK: - Inline runs

    static func attributed(
        _ runs: [MarkdownInline],
        size: CGFloat,
        weight: MarkdownTextWeight
    ) -> NSAttributedString {
        // Plain paragraphs (the overwhelming majority) skip the append loop.
        if runs.count == 1, let only = runs.first, only.kind == .text {
            return NSAttributedString(
                string: only.text,
                attributes: textAttributes(run: only, size: size, weight: weight)
            )
        }

        let output = NSMutableAttributedString()
        for run in runs {
            output.append(segment(run, size: size, weight: weight))
        }
        return output
    }

    private static func textAttributes(
        run: MarkdownInline,
        size: CGFloat,
        weight: MarkdownTextWeight
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(size: size, weight: weight, bold: run.bold, italic: run.italic),
            .foregroundColor: NSColor.labelColor
        ]
        if run.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    private static func segment(
        _ run: MarkdownInline,
        size: CGFloat,
        weight: MarkdownTextWeight
    ) -> NSAttributedString {
        switch run.kind {
        case .text:
            return NSAttributedString(
                string: run.text,
                attributes: textAttributes(run: run, size: size, weight: weight)
            )

        case .code:
            return NSAttributedString(
                string: " \(run.text) ",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.14)
                ]
            )

        case .link:
            var attributes = textAttributes(run: run, size: size, weight: weight)
            if let destination = run.destination {
                attributes[.link] = destination
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            return NSAttributedString(string: run.text, attributes: attributes)

        case .tag:
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(size: size, weight: weight, bold: run.bold, italic: run.italic),
                .foregroundColor: NSColor.controlAccentColor,
                .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.12)
            ]
            if let destination = run.destination {
                attributes[.link] = destination
            }
            return NSAttributedString(string: "#\(run.text)", attributes: attributes)

        case .wikilink:
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(size: size, weight: weight, bold: run.bold, italic: run.italic),
                .foregroundColor: NSColor.controlAccentColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.1)
            ]
            if let destination = run.destination {
                attributes[.link] = destination
            }
            return NSAttributedString(string: run.text, attributes: attributes)

        case .image:
            return NSAttributedString(
                string: "[\(run.text)]",
                attributes: [
                    .font: font(size: size, weight: .regular, bold: run.bold, italic: true),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )

        case .html:
            return NSAttributedString(
                string: run.text,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        }
    }

    // MARK: - Code blocks

    private static let tokenRegex: NSRegularExpression? = {
        // Strings are matched before flags so a `--flag` inside a quoted
        // argument keeps its string colour. `-- comment` does not match the
        // flag branch (no letter follows the dashes) and falls through to the
        // SQL comment branch.
        let pattern = #"(?<![\w])#[^\n]*|\/\*[\s\S]*?\*\/|\/\/[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`[^`]*`|(?<![\w-])--?[A-Za-z][\w-]*|--[^\n]*|\b\d+(?:\.\d+)?\b|\b(?:func|let|var|struct|class|enum|protocol|extension|import|return|if|else|guard|switch|case|default|for|while|in|break|continue|throw|throws|try|catch|async|await|actor|nonisolated|private|fileprivate|internal|public|static|final|override|init|deinit|self|Self|true|false|nil|def|from|as|with|yield|const|function|export|type|interface|implements|pub|fn|match|impl|use|mod|crate|select|from|where|insert|update|delete|join|group|order|having|limit|offset|create|table|index|into|values|set|and|or|not|null|is|like|between|distinct|count|sum|avg|min|max)\b"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let commandRegex: NSRegularExpression? = {
        let pattern = #"(?m)^([ \t]*)(sudo|brew|git|cd|ls|pwd|cp|mv|rm|mkdir|touch|cat|less|head|tail|grep|sed|awk|find|xargs|echo|export|source|chmod|chown|open|curl|wget|ssh|scp|rsync|docker|kubectl|npm|npx|yarn|pnpm|node|python|python3|pip|pip3|swift|xcodebuild|make|cmake|go|cargo|rustc|ruby|bundle|rails|psql|mysql|sqlite3|systemctl|launchctl|defaults|mas|gh)\b"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    static func highlighted(_ code: String, language: String?) -> NSAttributedString {
        let style = paragraphStyle(lineSpacing: 4, paragraphSpacing: 0)
        let attributed = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style
            ]
        )

        guard !code.isEmpty else { return attributed }
        let lang = language?.lowercased() ?? ""
        let isHashCommentLanguage = lang == "python" || lang == "py" || lang == "bash"
            || lang == "sh" || lang == "zsh" || lang == "yaml" || lang == "yml"
            || lang == "toml" || lang == "ruby" || lang == "rb"
        let isSQL = lang == "sql" || lang == "postgres" || lang == "postgresql"
        let stringColour = (isHashCommentLanguage || isSQL) ? NSColor.systemOrange : NSColor.systemRed

        let nsCode = code as NSString
        let fullRange = NSRange(location: 0, length: nsCode.length)
        if let regex = tokenRegex {
            for match in regex.matches(in: code, range: fullRange) {
                let token = nsCode.substring(with: match.range)
                if token.hasPrefix("#") {
                    // Swift `#if` is a directive, not a comment; bash, Python
                    // and YAML keep the familiar grey comment.
                    if isHashCommentLanguage || token.hasPrefix("# ") {
                        attributed.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
                    }
                } else if token.hasPrefix("//") || token.hasPrefix("/*") {
                    if !isHashCommentLanguage {
                        attributed.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
                    }
                } else if token.hasPrefix("--") {
                    if isSQL || token.hasPrefix("-- ") || token == "--" {
                        attributed.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
                    } else {
                        attributed.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: match.range)
                    }
                } else if token.hasPrefix("\"") || token.hasPrefix("'") || token.hasPrefix("`") {
                    attributed.addAttribute(.foregroundColor, value: stringColour, range: match.range)
                } else if token.hasPrefix("-") {
                    attributed.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: match.range)
                } else if token.first?.isNumber == true {
                    attributed.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: match.range)
                } else {
                    attributed.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: match.range)
                }
            }
        }

        if let commands = commandRegex {
            for match in commands.matches(in: code, range: fullRange) {
                let range = match.range(at: 2)
                guard range.location != NSNotFound else { continue }
                attributed.addAttributes(
                    [
                        .foregroundColor: NSColor.systemPurple,
                        .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
                    ],
                    range: range
                )
            }
        }

        return attributed
    }

    // MARK: - SwiftUI reading view

    /// The reading page is made of native SwiftUI blocks. Building an
    /// `AttributedString` here, instead of converting an `NSAttributedString`,
    /// keeps fonts and colours in SwiftUI's own attribute scope so `Text`
    /// renders them exactly as written.
    @MainActor
    static func swiftUIAttributed(
        _ lazy: LazyAttributed,
        baseColor: Color = .primary
    ) -> AttributedString {
        switch lazy.content {
        case let .runs(runs, size, weight):
            return swiftUIInline(runs, size: size, weight: weight, baseColor: baseColor)
        case let .code(code, language):
            return swiftUIHighlighted(code, language: language)
        }
    }

    @MainActor
    private static func swiftUIInline(
        _ runs: [MarkdownInline],
        size: CGFloat,
        weight: MarkdownTextWeight,
        baseColor: Color
    ) -> AttributedString {
        var output = AttributedString()
        for run in runs {
            let text: String = switch run.kind {
            case .code: " \(run.text) "
            case .tag: "#\(run.text)"
            case .image: "[\(run.text)]"
            default: run.text
            }

            var piece = AttributedString(text)
            piece.font = swiftUIFont(
                size: size,
                weight: weight,
                bold: run.bold,
                italic: run.italic || run.kind == .image
            )
            piece.foregroundColor = baseColor

            if run.strikethrough {
                piece.strikethroughStyle = .single
            }

            switch run.kind {
            case .code:
                piece.font = .system(size: 13.5, design: .monospaced)
                piece.foregroundColor = baseColor
                piece.backgroundColor = Color.primary.opacity(0.07)

            case .link:
                if let destination = run.destination {
                    piece.link = destination
                    piece.foregroundColor = .accentColor
                    piece.underlineStyle = .single
                }

            case .tag:
                piece.foregroundColor = .accentColor
                piece.backgroundColor = Color.accentColor.opacity(0.12)
                if let destination = run.destination {
                    piece.link = destination
                }

            case .wikilink:
                piece.foregroundColor = .accentColor
                piece.underlineStyle = .single
                piece.backgroundColor = Color.accentColor.opacity(0.1)
                if let destination = run.destination {
                    piece.link = destination
                }

            case .image:
                piece.foregroundColor = .secondary

            case .html:
                piece.font = .system(size: 13, design: .monospaced)
                piece.foregroundColor = .secondary

            case .text:
                break
            }

            output.append(piece)
        }
        return output
    }

    @MainActor
    private static func swiftUIFont(
        size: CGFloat,
        weight: MarkdownTextWeight,
        bold: Bool,
        italic: Bool
    ) -> Font {
        let resolvedWeight: Font.Weight = weight == .semibold || bold ? .semibold : .regular
        var font = Font.system(size: size, weight: resolvedWeight)
        if italic { font = font.italic() }
        return font
    }

    @MainActor
    private static func swiftUIHighlighted(_ code: String, language: String?) -> AttributedString {
        let normalized = code
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let baseFont = Font.system(size: 13, design: .monospaced)
        let boldFont = Font.system(size: 13, weight: .semibold, design: .monospaced)

        var base = AttributedString(normalized)
        base.font = baseFont
        base.foregroundColor = .primary
        guard !normalized.isEmpty else { return base }

        let lang = language?.lowercased() ?? ""
        let isHashCommentLanguage = lang == "python" || lang == "py" || lang == "bash"
            || lang == "sh" || lang == "zsh" || lang == "yaml" || lang == "yml"
            || lang == "toml" || lang == "ruby" || lang == "rb"
        let isSQL = lang == "sql" || lang == "postgres" || lang == "postgresql"
        let stringColour: Color = (isHashCommentLanguage || isSQL) ? .orange : .red

        struct Span {
            let range: NSRange
            let colour: Color
            let bold: Bool
            let priority: Int
        }

        var spans: [Span] = []
        let nsCode = normalized as NSString
        let fullRange = NSRange(location: 0, length: nsCode.length)

        if let regex = tokenRegex {
            for match in regex.matches(in: normalized, range: fullRange) {
                let token = nsCode.substring(with: match.range)
                guard let colour = tokenColour(
                    token,
                    isHashCommentLanguage: isHashCommentLanguage,
                    isSQL: isSQL,
                    stringColour: stringColour
                ) else { continue }
                // Strings and comments must win over a command-looking word
                // inside them (`echo "sudo rm"` keeps the string colour).
                spans.append(Span(range: match.range, colour: colour, bold: false, priority: 3))
            }
        }

        if let regex = commandRegex {
            for match in regex.matches(in: normalized, range: fullRange) {
                let range = match.range(at: 2)
                guard range.location != NSNotFound else { continue }
                spans.append(Span(range: range, colour: .purple, bold: true, priority: 2))
            }
        }

        guard !spans.isEmpty else { return base }

        // Split at every token boundary, then choose the highest-priority span
        // covering each slice. This avoids overlapping regex matches painting
        // one another in the wrong order.
        var boundaries: Set<Int> = [0, nsCode.length]
        for span in spans {
            boundaries.insert(span.range.location)
            boundaries.insert(NSMaxRange(span.range))
        }
        let ordered = boundaries.sorted()
        var output = AttributedString()

        for index in 0..<max(0, ordered.count - 1) {
            let start = ordered[index]
            let end = ordered[index + 1]
            guard end > start else { continue }
            let range = NSRange(location: start, length: end - start)
            let active = spans
                .filter { $0.range.location <= start && NSMaxRange($0.range) >= end }
                .max { $0.priority < $1.priority }

            var piece = AttributedString(nsCode.substring(with: range))
            piece.font = active?.bold == true ? boldFont : baseFont
            piece.foregroundColor = active?.colour ?? .primary
            output.append(piece)
        }

        return output
    }

    private static func tokenColour(
        _ token: String,
        isHashCommentLanguage: Bool,
        isSQL: Bool,
        stringColour: Color
    ) -> Color? {
        if token.hasPrefix("#") {
            // Swift `#if` is a directive, not a comment; bash, Python and YAML
            // keep the familiar grey comment.
            return (isHashCommentLanguage || token.hasPrefix("# ")) ? .secondary : nil
        }
        if token.hasPrefix("//") || token.hasPrefix("/*") {
            return isHashCommentLanguage ? nil : .secondary
        }
        if token.hasPrefix("--") {
            if isSQL || token.hasPrefix("-- ") || token == "--" {
                return .secondary
            }
            return .blue
        }
        if token.hasPrefix("\"") || token.hasPrefix("'") || token.hasPrefix("`") {
            return stringColour
        }
        if token.hasPrefix("-") { return .blue }
        if token.first?.isNumber == true { return .teal }
        return .purple
    }
}
