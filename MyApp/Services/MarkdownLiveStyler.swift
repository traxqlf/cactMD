import AppKit

/// Live Preview engine for the native Markdown editor (`MarkdownTextView`).
///
/// The engine never mutates `textStorage.string`: it only rewrites attributes
/// and asks the layout manager to drop the glyphs of the syntax delimiters
/// (`**`, `# `, `` ` ``, `[`, `](url)`…) with
/// `NSLayoutManager.GlyphProperty.null`. The saved `.md` file therefore stays
/// standard Markdown, the native `⌘Z` stack keeps working and selection offsets
/// never shift.
///
/// Styling is incremental: a text edit restyles only the paragraphs it touches,
/// while a selection change only rebuilds which delimiters are masked. Typing
/// or deleting a fence (```` ``` ````) is the one edit that rescans the whole
/// document, because it changes how every following block is read.
final class MarkdownLiveStyler: NSObject {
    private enum Metrics {
        static let bodySize: CGFloat = 15
        static let h1Size: CGFloat = 26
        static let h2Size: CGFloat = 21
        static let h3Size: CGFloat = 17
        static let h4Size: CGFloat = 15
        static let h5Size: CGFloat = 14
        static let h6Size: CGFloat = 13
        static let inlineCodeSize: CGFloat = 13.5
        static let blockCodeSize: CGFloat = 12.5
    }

    private static let bodyParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = 2
        return style
    }()

    private static let bodyAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: Metrics.bodySize),
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: bodyParagraphStyle
    ]

    /// Heading and quote metrics never change at runtime: share one style per
    /// level instead of allocating one per paragraph on every full restyle.
    private static let headingStyles: [NSParagraphStyle] = (0...6).map { level in
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        style.paragraphSpacingBefore = level == 1 ? 14 : level == 2 ? 10 : 6
        style.paragraphSpacing = level <= 2 ? 8 : 4
        return style
    }

    private static let quoteParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = 2
        style.headIndent = 16
        return style
    }()

    private static let codeParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.headIndent = 8
        style.firstLineHeadIndent = 8
        return style
    }()

    private static let monospacedCodeFont = NSFont.monospacedSystemFont(
        ofSize: Metrics.inlineCodeSize,
        weight: .regular
    )
    private static let monospacedBlockFont = NSFont.monospacedSystemFont(
        ofSize: Metrics.blockCodeSize,
        weight: .regular
    )

    /// Fonts are expensive to build (`NSFontManager` conversion) and the editor
    /// only ever needs a handful: cache them across restyles.
    private struct FontKey: Hashable {
        let size: CGFloat
        let semibold: Bool
        let bold: Bool
        let italic: Bool
    }

    private var fontCache: [FontKey: NSFont] = [:]

    // MARK: - Parsed model

    /// Heading or quote marker found at the start of a line.
    private struct LinePrefix {
        enum Kind {
            case heading(Int)
            case quote
        }

        let kind: Kind
        /// Delimiters to hide, relative to the paragraph start.
        let range: NSRange
        /// Length of the line without its newline, used for the cursor-on-line rule.
        let contentLength: Int
        /// Offset of the text that follows the marker, relative to the paragraph.
        let contentOffset: Int

        /// A heading or quote marker is revealed whenever the caret is on its line.
        func isRevealed(by selection: NSRange, base: Int) -> Bool {
            NSMaxRange(selection) > base && selection.location <= base + contentLength
        }
    }

    private struct ListMarker {
        /// Bullet, number and checkbox, relative to the paragraph start.
        let highlight: NSRange
        let contentOffset: Int
    }

    private struct InlineToken {
        enum Kind {
            case bold
            case italic
            case boldItalic
            case code
            case link
            case wikilink
        }

        let kind: Kind
        /// Whole element, delimiters included, relative to the paragraph start.
        let tokenRange: NSRange
        let contentRange: NSRange
        let delimiterRanges: [NSRange]
        /// Wikilink target (`Note` in `[[Note|Alias]]`); nil for inline markup.
        var destination: String? = nil

        /// Inline delimiters are revealed only when the selection touches the token.
        func isRevealed(by selection: NSRange, base: Int) -> Bool {
            let start = base + tokenRange.location
            let end = start + tokenRange.length
            return selection.location < end && NSMaxRange(selection) > start
        }

        func relative(to base: Int) -> InlineToken {
            InlineToken(
                kind: kind,
                tokenRange: NSRange(location: tokenRange.location - base, length: tokenRange.length),
                contentRange: NSRange(location: contentRange.location - base, length: contentRange.length),
                delimiterRanges: delimiterRanges.map {
                    NSRange(location: $0.location - base, length: $0.length)
                },
                destination: destination
            )
        }
    }

    private struct ParagraphEntry {
        var start: Int
        var prefix: LinePrefix?
        var tokens: [InlineToken]
    }

    // MARK: - State

    private weak var textView: NSTextView?
    private weak var layoutManager: NSLayoutManager?
    /// Guards the storage delegate against re-entrant restyling.
    private(set) var isApplyingStyling = false

    /// Paragraphs that carry markup, ordered by start offset.
    private var paragraphs: [ParagraphEntry] = []
    /// Fenced code blocks, ordered, as absolute document ranges.
    private var codeBlocks: [NSRange] = []
    /// Delimiters whose glyphs must be generated as `.null`, ordered and merged.
    private var hiddenRanges: [NSRange] = []
    private var lastSelection = NSRange(location: 0, length: 0)
    /// Typewriter mode: every paragraph but the edited one is dimmed.
    private var isFocusModeEnabled = false
    /// Start offset of the paragraph holding the caret, nil when focus is off.
    private var focusParagraphStart: Int?

    // MARK: - Lifecycle

    func install(on textView: NSTextView) {
        guard self.textView !== textView else { return }
        detach()
        self.textView = textView
        layoutManager = textView.layoutManager
        textView.textStorage?.delegate = self
        textView.layoutManager?.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSelectionChange(_:)),
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
        lastSelection = textView.selectedRange()
        restyleAll()
    }

    func detach() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSTextView.didChangeSelectionNotification,
            object: nil
        )
        if let textView {
            textView.textStorage?.delegate = nil
            textView.layoutManager?.delegate = nil
        }
        textView = nil
        layoutManager = nil
        paragraphs.removeAll()
        codeBlocks.removeAll()
        hiddenRanges.removeAll()
        focusParagraphStart = nil
    }

    /// Full pass, used when a note is loaded and when a fence line changes.
    func restyleAll() {
        guard let textView, let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        recomputeCodeBlocks(in: text)
        paragraphs.removeAll(keepingCapacity: true)
        hiddenRanges.removeAll(keepingCapacity: true)
        lastSelection = textView.selectedRange()
        if isFocusModeEnabled {
            focusParagraphStart = paragraphStart(at: textView.selectedRange().location, in: text)
        }
        restyle(NSRange(location: 0, length: text.length), text: text, storage: storage)
        invalidate(NSRange(location: 0, length: text.length), storage: storage)
    }

    /// Focus/typewriter mode. Only attributes change, so the note on disk and
    /// the undo stack are untouched.
    func setFocusMode(_ enabled: Bool) {
        guard isFocusModeEnabled != enabled else { return }
        isFocusModeEnabled = enabled
        if enabled, let textView, let storage = textView.textStorage {
            focusParagraphStart = paragraphStart(
                at: textView.selectedRange().location,
                in: storage.string as NSString
            )
        } else {
            focusParagraphStart = nil
        }
        restyleAll()
    }

    /// Wikilink under `index`, for click-to-open in the editor. Masked brackets
    /// have no glyphs, so the click index always lands on visible text.
    func wikilinkTarget(atCharacterIndex index: Int) -> String? {
        guard !paragraphs.isEmpty else { return nil }

        var low = 0
        var high = paragraphs.count - 1
        var candidate = -1
        while low <= high {
            let middle = (low + high) / 2
            if paragraphs[middle].start <= index {
                candidate = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard candidate >= 0 else { return nil }

        let entry = paragraphs[candidate]
        for token in entry.tokens where token.kind == .wikilink {
            let start = entry.start + token.tokenRange.location
            guard index >= start, index < start + token.tokenRange.length else { continue }
            return token.destination
        }
        return nil
    }

    // MARK: - Styling passes

    private func restyle(_ paragraphRange: NSRange, text: NSString, storage: NSTextStorage) {
        var entries: [ParagraphEntry] = []
        isApplyingStyling = true
        storage.beginEditing()
        forEachParagraph(in: paragraphRange, text: text) { paragraph in
            if let entry = styleParagraph(paragraph, text: text, storage: storage) {
                entries.append(entry)
            }
        }
        storage.endEditing()
        isApplyingStyling = false

        replaceParagraphs(in: paragraphRange, with: entries)
        lastSelection = textView?.selectedRange() ?? lastSelection
        rebuildHiddenRanges(selection: lastSelection)
        // A character edit already invalidated the edited paragraph's glyphs,
        // and rewriting its attributes invalidates them again: invalidating a
        // second time here only confused the layout manager's glyph offsets.
    }

    private func replaceParagraphs(in range: NSRange, with entries: [ParagraphEntry]) {
        let lower = firstParagraphIndex(atOrAfter: range.location)
        let upper = firstParagraphIndex(atOrAfter: NSMaxRange(range))
        paragraphs.replaceSubrange(lower..<upper, with: entries)
    }

    private func forEachParagraph(in range: NSRange, text: NSString, _ body: (NSRange) -> Void) {
        guard text.length > 0 else {
            body(NSRange(location: 0, length: 0))
            return
        }

        let limit = min(max(NSMaxRange(range), 0), text.length)
        var index = min(max(range.location, 0), text.length)
        while true {
            var start = 0
            var end = 0
            var contentsEnd = 0
            text.getParagraphStart(
                &start,
                end: &end,
                contentsEnd: &contentsEnd,
                for: NSRange(location: index, length: 0)
            )
            body(NSRange(location: start, length: end - start))
            guard end > index, end < text.length, end < limit else { break }
            index = end
        }
    }

    private func firstParagraphIndex(atOrAfter location: Int) -> Int {
        var low = 0
        var high = paragraphs.count
        while low < high {
            let middle = (low + high) / 2
            if paragraphs[middle].start < location {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// Styles one paragraph and returns its markup entry, or `nil` when the
    /// paragraph is plain text with nothing to mask.
    private func styleParagraph(
        _ paragraph: NSRange,
        text: NSString,
        storage: NSTextStorage
    ) -> ParagraphEntry? {
        let contents = paragraphContents(paragraph, in: text)
        storage.setAttributes(Self.bodyAttributes, range: paragraph)
        guard contents.length > 0 else { return nil }

        if isInsideCodeBlock(contents.location) {
            styleCodeParagraph(paragraph, contents: contents, text: text, storage: storage)
            return nil
        }

        let base = paragraph.location
        var baseSize = Metrics.bodySize
        var baseColor = NSColor.labelColor
        var inlineStart = contents.location
        var prefix: LinePrefix?

        if let linePrefix = leadingPrefix(text, contents: contents, paragraph: paragraph) {
            prefix = linePrefix
            inlineStart = base + linePrefix.contentOffset

            switch linePrefix.kind {
            case .heading(let level):
                baseSize = headingSize(level)
                storage.addAttributes(
                    [
                        .font: headingFont(level),
                        .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: Self.headingStyles[level]
                    ],
                    range: paragraph
                )
                storage.addAttribute(
                    .foregroundColor,
                    value: NSColor.tertiaryLabelColor,
                    range: absolute(linePrefix.range, base: base)
                )

            case .quote:
                baseColor = NSColor.secondaryLabelColor
                storage.addAttributes(
                    [.foregroundColor: baseColor, .paragraphStyle: Self.quoteParagraphStyle],
                    range: paragraph
                )
                storage.addAttribute(
                    .foregroundColor,
                    value: NSColor.tertiaryLabelColor,
                    range: absolute(linePrefix.range, base: base)
                )
            }
        }

        if let marker = listMarker(text, from: inlineStart, end: NSMaxRange(contents), base: base) {
            storage.addAttributes(
                [
                    .font: font(size: baseSize, semibold: true),
                    .foregroundColor: NSColor.controlAccentColor
                ],
                range: absolute(marker.highlight, base: base)
            )
            inlineStart = base + marker.contentOffset
        }

        var tokens: [InlineToken] = []
        let inlineLength = max(0, NSMaxRange(contents) - inlineStart)
        if inlineLength > 0 {
            let parsed = tokenize(text, range: NSRange(location: inlineStart, length: inlineLength))
            if !parsed.isEmpty {
                tokens = parsed.map { $0.relative(to: base) }
                apply(tokens, baseSize: baseSize, baseColor: baseColor, base: base, storage: storage)
            }
        }

        applyFocusDimming(paragraph, storage: storage)

        guard prefix != nil || !tokens.isEmpty else { return nil }
        return ParagraphEntry(start: base, prefix: prefix, tokens: tokens)
    }

    private func styleCodeParagraph(
        _ paragraph: NSRange,
        contents: NSRange,
        text: NSString,
        storage: NSTextStorage
    ) {
        let isFence = fenceMarker(in: text, contents: contents) != nil
        var attributes: [NSAttributedString.Key: Any] = [
            .font: Self.monospacedBlockFont,
            .foregroundColor: isFence ? NSColor.tertiaryLabelColor : NSColor.labelColor,
            .paragraphStyle: Self.codeParagraphStyle
        ]
        if !isFence {
            attributes[.backgroundColor] = NSColor.quaternaryLabelColor
        }
        storage.addAttributes(attributes, range: paragraph)
        applyFocusDimming(paragraph, storage: storage)
    }

    // MARK: - Line syntax

    private func paragraphContents(_ paragraph: NSRange, in text: NSString) -> NSRange {
        var length = paragraph.length
        while length > 0 {
            let character = text.character(at: paragraph.location + length - 1)
            guard character == 10 || character == 13 else { break }
            length -= 1
        }
        return NSRange(location: paragraph.location, length: length)
    }

    private func leadingPrefix(_ text: NSString, contents: NSRange, paragraph: NSRange) -> LinePrefix? {
        let end = NSMaxRange(contents)
        var cursor = contents.location
        var spaces = 0
        while cursor < end, spaces < 3, text.character(at: cursor) == 32 {
            cursor += 1
            spaces += 1
        }
        guard cursor < end else { return nil }

        let base = paragraph.location
        let contentLength = contents.length

        if text.character(at: cursor) == 35 { // '#'
            let prefixStart = cursor
            var level = 0
            while cursor < end, level < 6, text.character(at: cursor) == 35 {
                level += 1
                cursor += 1
            }
            guard cursor < end,
                  text.character(at: cursor) == 32 || text.character(at: cursor) == 9 else {
                return nil
            }
            while cursor < end,
                  text.character(at: cursor) == 32 || text.character(at: cursor) == 9 {
                cursor += 1
            }
            return LinePrefix(
                kind: .heading(level),
                range: NSRange(location: prefixStart - base, length: cursor - prefixStart),
                contentLength: contentLength,
                contentOffset: cursor - base
            )
        }

        if text.character(at: cursor) == 62 { // '>'
            let prefixStart = cursor
            while cursor < end, text.character(at: cursor) == 62 {
                cursor += 1
                if cursor < end, text.character(at: cursor) == 32 || text.character(at: cursor) == 9 {
                    cursor += 1
                }
            }
            return LinePrefix(
                kind: .quote,
                range: NSRange(location: prefixStart - base, length: cursor - prefixStart),
                contentLength: contentLength,
                contentOffset: cursor - base
            )
        }

        return nil
    }

    private func listMarker(_ text: NSString, from start: Int, end: Int, base: Int) -> ListMarker? {
        var cursor = start
        while cursor < end,
              text.character(at: cursor) == 32 || text.character(at: cursor) == 9 {
            cursor += 1
        }
        guard cursor < end else { return nil }

        let markerStart = cursor
        let character = text.character(at: cursor)
        if character == 45 || character == 42 || character == 43 { // - * +
            cursor += 1
            guard cursor < end,
                  text.character(at: cursor) == 32 || text.character(at: cursor) == 9 else {
                return nil
            }
        } else if character >= 48, character <= 57 {
            var digits = 0
            while cursor < end, digits < 9,
                  text.character(at: cursor) >= 48, text.character(at: cursor) <= 57 {
                cursor += 1
                digits += 1
            }
            guard cursor < end,
                  text.character(at: cursor) == 46 || text.character(at: cursor) == 41 else {
                return nil
            }
            cursor += 1
            guard cursor < end,
                  text.character(at: cursor) == 32 || text.character(at: cursor) == 9 else {
                return nil
            }
        } else {
            return nil
        }

        while cursor < end,
              text.character(at: cursor) == 32 || text.character(at: cursor) == 9 {
            cursor += 1
        }
        var contentStart = cursor

        // `- [ ]` / `- [x]` checkbox: highlighted with the bullet, skipped by the
        // inline scanner so its brackets are never mistaken for a link.
        if cursor + 2 < end, text.character(at: cursor) == 91 {
            let state = text.character(at: cursor + 1)
            let closing = text.character(at: cursor + 2)
            if closing == 93, state == 32 || state == 120 || state == 88 {
                var after = cursor + 3
                if after < end,
                   text.character(at: after) == 32 || text.character(at: after) == 9 {
                    after += 1
                }
                contentStart = after
            }
        }

        return ListMarker(
            highlight: NSRange(location: markerStart - base, length: contentStart - markerStart),
            contentOffset: contentStart - base
        )
    }

    private func absolute(_ range: NSRange, base: Int) -> NSRange {
        NSRange(location: base + range.location, length: range.length)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return Metrics.h1Size
        case 2: return Metrics.h2Size
        case 3: return Metrics.h3Size
        case 4: return Metrics.h4Size
        case 5: return Metrics.h5Size
        default: return Metrics.h6Size
        }
    }

    private func headingFont(_ level: Int) -> NSFont {
        if level <= 2 {
            return font(size: headingSize(level), semibold: false, bold: true, italic: false)
        }
        return font(size: headingSize(level), semibold: true, bold: false, italic: false)
    }

    private func font(
        size: CGFloat,
        semibold: Bool = false,
        bold: Bool = false,
        italic: Bool = false
    ) -> NSFont {
        let key = FontKey(size: size, semibold: semibold, bold: bold, italic: italic)
        if let cached = fontCache[key] { return cached }
        let font: NSFont
        if bold || italic {
            font = MarkdownTextStyler.font(
                size: size,
                weight: semibold ? .semibold : .regular,
                bold: bold,
                italic: italic
            )
        } else {
            font = MarkdownTextStyler.font(size: size, weight: semibold ? .semibold : .regular)
        }
        if fontCache.count > 48 { fontCache.removeAll(keepingCapacity: true) }
        fontCache[key] = font
        return font
    }

    // MARK: - Inline syntax

    private func tokenize(_ text: NSString, range: NSRange) -> [InlineToken] {
        var tokens: [InlineToken] = []
        var index = range.location
        let end = NSMaxRange(range)

        while index < end {
            switch text.character(at: index) {
            case 96: // '`'
                if let token = codeSpan(text, at: index, end: end) {
                    tokens.append(token)
                    index = NSMaxRange(token.tokenRange)
                    continue
                }
            case 42, 95: // '*' '_'
                if let token = emphasis(text, at: index, end: end) {
                    tokens.append(token)
                    index = NSMaxRange(token.tokenRange)
                    continue
                }
            case 91: // '['
                if index + 1 < end, text.character(at: index + 1) == 91 { // '[['
                    if let token = wikilink(text, at: index, end: end) {
                        tokens.append(token)
                        index = NSMaxRange(token.tokenRange)
                        continue
                    }
                } else if index > range.location, text.character(at: index - 1) == 33 { // '!'
                    // Images keep their Markdown visible; only skip their URL.
                    if let image = link(text, at: index, end: end) {
                        index = NSMaxRange(image.tokenRange)
                        continue
                    }
                } else if let token = link(text, at: index, end: end) {
                    tokens.append(token)
                    index = NSMaxRange(token.tokenRange)
                    continue
                }
            default:
                break
            }
            index += 1
        }

        return tokens
    }

    private func codeSpan(_ text: NSString, at start: Int, end: Int) -> InlineToken? {
        var cursor = start + 1
        while cursor < end {
            if text.character(at: cursor) == 96, !isEscaped(text, at: cursor) {
                let content = NSRange(location: start + 1, length: cursor - start - 1)
                guard content.length > 0 else { return nil }
                return InlineToken(
                    kind: .code,
                    tokenRange: NSRange(location: start, length: cursor + 1 - start),
                    contentRange: content,
                    delimiterRanges: [
                        NSRange(location: start, length: 1),
                        NSRange(location: cursor, length: 1)
                    ]
                )
            }
            cursor += 1
        }
        return nil
    }

    private func emphasis(_ text: NSString, at start: Int, end: Int) -> InlineToken? {
        let marker = text.character(at: start)
        var openingRun = 0
        while openingRun < 3, start + openingRun < end,
              text.character(at: start + openingRun) == marker {
            openingRun += 1
        }
        guard openingRun > 0, start + openingRun < end else { return nil }
        // `snake_case` is not emphasis: `_` must not open inside a word.
        if marker == 95, start > 0, isWordCharacter(text.character(at: start - 1)) {
            return nil
        }
        guard !isSpace(text.character(at: start + openingRun)) else { return nil }

        var exactClose: (index: Int, run: Int)?
        var looseClose: (index: Int, run: Int)?
        var cursor = start + openingRun + 1

        while cursor < end {
            guard text.character(at: cursor) == marker, !isEscaped(text, at: cursor) else {
                cursor += 1
                continue
            }
            var run = 0
            while cursor + run < end, run < 3, text.character(at: cursor + run) == marker {
                run += 1
            }
            let previous = text.character(at: cursor - 1)
            let following: unichar = cursor + run < end ? text.character(at: cursor + run) : 0
            let hugsText = !isSpace(previous) && previous != 10 && previous != 13
            let wordSafe = !(marker == 95 && isWordCharacter(following))

            if hugsText, wordSafe {
                if run == openingRun {
                    exactClose = (cursor, run)
                    break
                }
                if run > openingRun, looseClose == nil {
                    looseClose = (cursor, openingRun)
                }
            }
            cursor += max(run, 1)
        }

        guard let close = exactClose ?? looseClose else { return nil }
        let content = NSRange(location: start + openingRun, length: close.index - start - openingRun)
        guard content.length > 0 else { return nil }

        let kind: InlineToken.Kind = switch openingRun {
        case 1: .italic
        case 2: .bold
        default: .boldItalic
        }

        return InlineToken(
            kind: kind,
            tokenRange: NSRange(location: start, length: close.index + close.run - start),
            contentRange: content,
            delimiterRanges: [
                NSRange(location: start, length: openingRun),
                NSRange(location: close.index, length: close.run)
            ]
        )
    }

    private func link(_ text: NSString, at start: Int, end: Int) -> InlineToken? {
        var cursor = start + 1
        while cursor < end {
            switch text.character(at: cursor) {
            case 92: // '\\'
                cursor += 2
                continue
            case 91, 10: // '[' nested, newline
                return nil
            case 93: // ']'
                break
            default:
                cursor += 1
                continue
            }
            break
        }
        guard cursor < end, text.character(at: cursor) == 93 else { return nil }

        let titleEnd = cursor
        guard titleEnd + 1 < end, text.character(at: titleEnd + 1) == 40 else { return nil }

        var destination = titleEnd + 2
        while destination < end {
            switch text.character(at: destination) {
            case 92:
                destination += 2
                continue
            case 41: // ')'
                break
            case 10:
                return nil
            default:
                destination += 1
                continue
            }
            break
        }
        guard destination < end,
              text.character(at: destination) == 41,
              destination > titleEnd + 2 else {
            return nil
        }

        let content = NSRange(location: start + 1, length: titleEnd - start - 1)
        guard content.length > 0 else { return nil }

        return InlineToken(
            kind: .link,
            tokenRange: NSRange(location: start, length: destination + 1 - start),
            contentRange: content,
            delimiterRanges: [
                NSRange(location: start, length: 1),
                NSRange(location: titleEnd, length: destination + 1 - titleEnd)
            ]
        )
    }

    /// `[[Note]]` and `[[Note|Alias]]`: the alias (or the target) is styled as a
    /// link, the brackets and the target of an aliased link are masked. The
    /// whole token is revealed while the caret is inside it, so the raw syntax
    /// is always editable.
    private func wikilink(_ text: NSString, at start: Int, end: Int) -> InlineToken? {
        var cursor = start + 2
        while cursor + 1 < end {
            let character = text.character(at: cursor)
            if character == 10 || character == 13 || character == 91 { return nil }
            guard character == 93, text.character(at: cursor + 1) == 93 else {
                cursor += 1
                continue
            }

            let inside = NSRange(location: start + 2, length: cursor - start - 2)
            guard inside.length > 0 else { return nil }
            let inner = text.substring(with: inside) as NSString
            let pipe = inner.range(of: "|")

            let targetRange: NSRange
            let displayRange: NSRange
            let delimiters: [NSRange]
            if pipe.location != NSNotFound {
                targetRange = NSRange(location: inside.location, length: pipe.location)
                displayRange = NSRange(
                    location: inside.location + pipe.location + 1,
                    length: inside.length - pipe.location - 1
                )
                delimiters = [
                    NSRange(location: start, length: displayRange.location - start),
                    NSRange(location: cursor, length: 2)
                ]
            } else {
                targetRange = inside
                displayRange = inside
                delimiters = [
                    NSRange(location: start, length: 2),
                    NSRange(location: cursor, length: 2)
                ]
            }

            guard displayRange.length > 0 else { return nil }
            let target = (text.substring(with: targetRange) as NSString)
                .trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return nil }

            return InlineToken(
                kind: .wikilink,
                tokenRange: NSRange(location: start, length: cursor + 2 - start),
                contentRange: displayRange,
                delimiterRanges: delimiters,
                destination: target
            )
        }
        return nil
    }

    private func apply(
        _ tokens: [InlineToken],
        baseSize: CGFloat,
        baseColor: NSColor,
        base: Int,
        storage: NSTextStorage
    ) {
        for token in tokens {
            let content = absolute(token.contentRange, base: base)
            switch token.kind {
            case .bold:
                storage.addAttribute(
                    .font,
                    value: font(size: baseSize, bold: true),
                    range: content
                )
            case .italic:
                storage.addAttribute(
                    .font,
                    value: font(size: baseSize, italic: true),
                    range: content
                )
            case .boldItalic:
                storage.addAttribute(
                    .font,
                    value: font(size: baseSize, bold: true, italic: true),
                    range: content
                )
            case .code:
                storage.addAttributes(
                    [
                        .font: Self.monospacedCodeFont,
                        .foregroundColor: baseColor,
                        .backgroundColor: NSColor.quaternaryLabelColor
                    ],
                    range: content
                )
            case .link, .wikilink:
                storage.addAttributes(
                    [
                        .foregroundColor: NSColor.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ],
                    range: content
                )
            }

            // Delimiters stay tertiary when revealed; their glyphs are dropped
            // entirely while masked, so the colour never shows through.
            for delimiter in token.delimiterRanges {
                storage.addAttribute(
                    .foregroundColor,
                    value: NSColor.tertiaryLabelColor,
                    range: absolute(delimiter, base: base)
                )
            }
        }
    }

    private func isSpace(_ character: unichar) -> Bool {
        character == 32 || character == 9 || character == 10 || character == 13
    }

    private func isWordCharacter(_ character: unichar) -> Bool {
        (character >= 48 && character <= 57)
            || (character >= 65 && character <= 90)
            || (character >= 97 && character <= 122)
            || character > 127
    }

    private func isEscaped(_ text: NSString, at index: Int) -> Bool {
        var backslashes = 0
        var cursor = index - 1
        while cursor >= 0, text.character(at: cursor) == 92 {
            backslashes += 1
            cursor -= 1
        }
        return backslashes % 2 == 1
    }

    // MARK: - Fenced code blocks

    private func recomputeCodeBlocks(in text: NSString) {
        var blocks: [NSRange] = []
        var openStart: Int?
        var openMarker: unichar = 0

        forEachParagraph(in: NSRange(location: 0, length: text.length), text: text) { paragraph in
            let contents = paragraphContents(paragraph, in: text)
            guard let marker = fenceMarker(in: text, contents: contents) else { return }

            if let start = openStart {
                guard marker == openMarker else { return }
                blocks.append(NSRange(location: start, length: NSMaxRange(paragraph) - start))
                openStart = nil
            } else {
                openStart = paragraph.location
                openMarker = marker
            }
        }

        if let start = openStart, start < text.length {
            blocks.append(NSRange(location: start, length: text.length - start))
        }
        codeBlocks = blocks
    }

    private func fenceMarker(in text: NSString, contents: NSRange) -> unichar? {
        let end = NSMaxRange(contents)
        var cursor = contents.location
        var spaces = 0
        while cursor < end, spaces < 3, text.character(at: cursor) == 32 {
            cursor += 1
            spaces += 1
        }
        guard cursor < end else { return nil }

        let marker = text.character(at: cursor)
        guard marker == 96 || marker == 126 else { return nil }
        var run = 0
        while cursor < end, text.character(at: cursor) == marker {
            cursor += 1
            run += 1
        }
        return run >= 3 ? marker : nil
    }

    private func isInsideCodeBlock(_ location: Int) -> Bool {
        for block in codeBlocks where location >= block.location && location < NSMaxRange(block) {
            return true
        }
        return false
    }

    /// Shifts the cached blocks with the edit, expanding the one that contains it.
    private func shiftCodeBlocks(delta: Int, editedRange: NSRange) {
        guard delta != 0, !codeBlocks.isEmpty else { return }
        let oldEnd = NSMaxRange(editedRange) - delta

        for index in codeBlocks.indices {
            var block = codeBlocks[index]
            if block.location >= oldEnd {
                block.location += delta
            } else if NSMaxRange(editedRange) >= block.location,
                      editedRange.location <= NSMaxRange(block) {
                block.length += delta
            }
            codeBlocks[index] = block
        }
        codeBlocks.removeAll { $0.length <= 0 || $0.location < 0 }
    }

    /// A fence was typed, removed or moved: blocks must be scanned again.
    private func needsCodeBlockRescan(in text: NSString, around paragraph: NSRange) -> Bool {
        if containsFenceMarker(text, paragraphContents(paragraph, in: text)) { return true }

        if paragraph.location > 0 {
            var start = 0
            var end = 0
            var contentsEnd = 0
            text.getParagraphStart(
                &start,
                end: &end,
                contentsEnd: &contentsEnd,
                for: NSRange(location: paragraph.location - 1, length: 0)
            )
            if containsFenceMarker(text, NSRange(location: start, length: contentsEnd - start)) {
                return true
            }
        }

        if NSMaxRange(paragraph) < text.length {
            var start = 0
            var end = 0
            var contentsEnd = 0
            text.getParagraphStart(
                &start,
                end: &end,
                contentsEnd: &contentsEnd,
                for: NSRange(location: NSMaxRange(paragraph), length: 0)
            )
            if containsFenceMarker(text, NSRange(location: start, length: contentsEnd - start)) {
                return true
            }
        }

        return false
    }

    private func containsFenceMarker(_ text: NSString, _ contents: NSRange) -> Bool {
        guard contents.length >= 3, contents.length <= 4_000 else {
            return contents.length > 4_000
        }
        let line = text.substring(with: contents)
        return line.contains("```") || line.contains("~~~")
    }

    /// Cheap sanity check: every cached block must still start on a fence line.
    private func codeBlocksMatchText(_ text: NSString) -> Bool {
        for block in codeBlocks {
            guard block.length > 0, block.location < text.length else { return false }
            let line = text.lineRange(for: NSRange(location: block.location, length: 0))
            guard line.location == block.location else { return false }
            guard fenceMarker(in: text, contents: paragraphContents(line, in: text)) != nil else {
                return false
            }

            let end = NSMaxRange(block)
            if end < text.length {
                let closing = text.lineRange(for: NSRange(location: max(block.location, end - 1), length: 0))
                guard fenceMarker(in: text, contents: paragraphContents(closing, in: text)) != nil else {
                    return false
                }
            }
        }
        return true
    }

    // MARK: - Glyph masking

    private func rebuildHiddenRanges(selection: NSRange) {
        var ranges: [NSRange] = []
        ranges.reserveCapacity(hiddenRanges.count)

        for entry in paragraphs {
            if let prefix = entry.prefix, !prefix.isRevealed(by: selection, base: entry.start) {
                ranges.append(NSRange(
                    location: entry.start + prefix.range.location,
                    length: prefix.range.length
                ))
            }
            for token in entry.tokens where !token.isRevealed(by: selection, base: entry.start) {
                for delimiter in token.delimiterRanges {
                    ranges.append(NSRange(
                        location: entry.start + delimiter.location,
                        length: delimiter.length
                    ))
                }
            }
        }

        hiddenRanges = Self.merged(ranges)
    }

    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var output: [NSRange] = []
        output.reserveCapacity(ranges.count)
        for range in ranges where range.length > 0 {
            if let last = output.last, range.location <= NSMaxRange(last) {
                let end = max(NSMaxRange(last), NSMaxRange(range))
                output[output.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                output.append(range)
            }
        }
        return output
    }

    private func containsHidden(_ characterIndex: Int) -> Bool {
        var low = 0
        var high = hiddenRanges.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = hiddenRanges[middle]
            if characterIndex < range.location {
                high = middle - 1
            } else if characterIndex >= NSMaxRange(range) {
                low = middle + 1
            } else {
                return true
            }
        }
        return false
    }

    private func invalidate(_ range: NSRange, storage: NSTextStorage) {
        guard let layoutManager, storage.length > 0 else { return }
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard clamped.length > 0 else { return }
        layoutManager.invalidateGlyphs(
            forCharacterRange: clamped,
            changeInLength: 0,
            actualCharacterRange: nil
        )
        layoutManager.invalidateLayout(forCharacterRange: clamped, actualCharacterRange: nil)
    }

    // MARK: - Incremental updates

    private func paragraphStart(at location: Int, in text: NSString) -> Int? {
        guard text.length > 0 else { return nil }
        return paragraphRange(for: NSRange(location: location, length: 0), in: text).location
    }

    /// Moves the focus to the paragraph under the caret, restyling the one it
    /// leaves and the one it enters so the dimming follows along.
    private func updateFocusedParagraph(selection: NSRange, text: NSString, storage: NSTextStorage) {
        guard isFocusModeEnabled, text.length > 0 else { return }
        guard let start = paragraphStart(at: selection.location, in: text) else { return }
        guard start != focusParagraphStart else { return }

        var range = paragraphRange(for: selection, in: text)
        if let previous = focusParagraphStart {
            range = NSUnionRange(
                range,
                paragraphRange(for: NSRange(location: previous, length: 0), in: text)
            )
        }
        focusParagraphStart = start
        restyle(range, text: text, storage: storage)
    }

    private func applyFocusDimming(_ paragraph: NSRange, storage: NSTextStorage) {
        guard isFocusModeEnabled, let focusParagraphStart else { return }
        guard paragraph.location != focusParagraphStart else { return }
        storage.addAttribute(
            .foregroundColor,
            value: NSColor.secondaryLabelColor,
            range: paragraph
        )
    }

    private func paragraphRange(for selection: NSRange, in text: NSString) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let location = min(max(selection.location, 0), text.length)
        let length = min(selection.length, text.length - location)
        return text.paragraphRange(for: NSRange(location: location, length: length))
    }

    /// Drops the entries the edit replaced and shifts the ones that follow it.
    private func adjustParagraphs(editedRange: NSRange, changeInLength delta: Int) {
        guard !paragraphs.isEmpty else { return }
        let oldEnd = NSMaxRange(editedRange) - delta
        var index = firstParagraphIndex(atOrAfter: editedRange.location)

        while index < paragraphs.count {
            let start = paragraphs[index].start
            if start >= oldEnd {
                paragraphs[index].start = start + delta
                index += 1
            } else {
                paragraphs.remove(at: index)
            }
        }
    }

    private func applyEdit(
        editedRange: NSRange,
        changeInLength delta: Int,
        text: NSString,
        storage: NSTextStorage
    ) {
        let location = min(max(editedRange.location, 0), text.length)
        let length = min(editedRange.length, text.length - location)
        let edited = NSRange(location: location, length: length)
        var paragraph = text.length > 0
            ? text.paragraphRange(for: edited)
            : NSRange(location: 0, length: 0)

        // Return splits a paragraph: the new one inherits the heading or quote
        // style of the line above, so restyle it in the same pass.
        if NSMaxRange(paragraph) < text.length, containsLineBreak(text, in: edited) {
            var start = 0
            var end = 0
            var contentsEnd = 0
            text.getParagraphStart(
                &start,
                end: &end,
                contentsEnd: &contentsEnd,
                for: NSRange(location: NSMaxRange(paragraph), length: 0)
            )
            paragraph = NSRange(location: paragraph.location, length: end - paragraph.location)
        }

        shiftCodeBlocks(delta: delta, editedRange: editedRange)
        if needsCodeBlockRescan(in: text, around: paragraph) || !codeBlocksMatchText(text) {
            restyleAll()
            return
        }

        adjustParagraphs(editedRange: editedRange, changeInLength: delta)
        restyle(paragraph, text: text, storage: storage)

        if isFocusModeEnabled {
            updateFocusedParagraph(
                selection: textView?.selectedRange() ?? NSRange(location: 0, length: 0),
                text: text,
                storage: storage
            )
        }
    }

    private func containsLineBreak(_ text: NSString, in range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        for index in range.location..<NSMaxRange(range) {
            let character = text.character(at: index)
            if character == 10 || character == 13 { return true }
        }
        return false
    }

    @objc private func handleSelectionChange(_ notification: Notification) {
        guard let textView, let storage = textView.textStorage, !isApplyingStyling else { return }
        guard !textView.hasMarkedText() else { return }

        let selection = textView.selectedRange()
        guard selection != lastSelection else { return }

        let text = storage.string as NSString
        let previous = hiddenRanges
        let previousParagraph = paragraphRange(for: lastSelection, in: text)
        lastSelection = selection

        updateFocusedParagraph(selection: selection, text: text, storage: storage)

        rebuildHiddenRanges(selection: selection)
        guard hiddenRanges != previous else { return }

        let currentParagraph = paragraphRange(for: selection, in: text)
        invalidate(NSUnionRange(previousParagraph, currentParagraph), storage: storage)
    }
}

// MARK: - NSTextStorageDelegate

extension MarkdownLiveStyler: NSTextStorageDelegate {
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters), !isApplyingStyling else { return }
        guard let textView, textView.textStorage === textStorage else { return }
        guard !textView.hasMarkedText() else { return }
        applyEdit(
            editedRange: editedRange,
            changeInLength: delta,
            text: textStorage.string as NSString,
            storage: textStorage
        )
    }
}

// MARK: - NSLayoutManagerDelegate

extension MarkdownLiveStyler: NSLayoutManagerDelegate {
    /// Drops the glyphs of masked delimiters: `.null` makes their width zero, so
    /// the text closes up cleanly without any character being removed.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard !hiddenRanges.isEmpty else { return 0 }
        let count = glyphRange.length
        guard count > 0 else { return 0 }

        return withUnsafeTemporaryAllocation(
            of: NSLayoutManager.GlyphProperty.self,
            capacity: count
        ) { buffer in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            var changed = false

            for offset in 0..<count {
                let property = props[offset]
                if containsHidden(charIndexes[offset]) {
                    baseAddress[offset] = property.union(.null)
                    changed = true
                } else {
                    baseAddress[offset] = property
                }
            }

            guard changed else { return 0 }
            layoutManager.setGlyphs(
                glyphs,
                properties: baseAddress,
                characterIndexes: charIndexes,
                font: aFont,
                forGlyphRange: glyphRange
            )
            return count
        }
    }
}
