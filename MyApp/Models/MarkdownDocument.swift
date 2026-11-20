import CoreGraphics
import Foundation

nonisolated enum MarkdownTableAlignment: Sendable {
    case left
    case center
    case right
}

/// One styled run of inline content. Keeping runs instead of a ready-made
/// `AttributedString` is what makes the reader cheap on long notes: the
/// expensive attribute graph is only built for the blocks a `LazyVStack`
/// actually paints.
nonisolated struct MarkdownInline: @unchecked Sendable {
    enum Kind: UInt8, Sendable {
        case text
        case code
        case link
        case tag
        case wikilink
        case image
        case html
    }

    var text: String
    var kind: Kind
    var bold: Bool
    var italic: Bool
    var strikethrough: Bool
    /// External destination for `.link`, `systemmd://` destination for
    /// `.tag` and `.wikilink`.
    var destination: URL?

    init(
        _ text: String,
        kind: Kind = .text,
        bold: Bool = false,
        italic: Bool = false,
        strikethrough: Bool = false,
        destination: URL? = nil
    ) {
        self.text = text
        self.kind = kind
        self.bold = bold
        self.italic = italic
        self.strikethrough = strikethrough
        self.destination = destination
    }
}

nonisolated enum MarkdownTextWeight: Sendable {
    case regular
    case semibold
}

/// A block's styled text, materialised on first use and then kept.
///
/// `plainText` is always available: the status bar, the outline and the tag
/// scanner never need the styled version. The styled version is the AppKit
/// `NSAttributedString` the reader's `NSTextView` is fed with, built by
/// `MarkdownTextStyler` from the same runs the parser produced.
nonisolated final class LazyAttributed: @unchecked Sendable {
    nonisolated enum Content: @unchecked Sendable {
        case runs([MarkdownInline], size: CGFloat, weight: MarkdownTextWeight)
        case code(String, language: String?)
    }

    let plainText: String
    let content: Content
    private var cached: NSAttributedString?
    private let lock = NSLock()

    init(plainText: String, content: Content) {
        self.plainText = plainText
        self.content = content
    }

    var nsAttributed: NSAttributedString {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Built outside the lock: the build is pure, and two concurrent first
        // calls just produce the same value.
        let built = switch content {
        case let .runs(runs, size, weight):
            MarkdownTextStyler.attributed(runs, size: size, weight: weight)
        case let .code(code, language):
            MarkdownTextStyler.highlighted(code, language: language)
        }

        lock.lock()
        if cached == nil {
            cached = built
        }
        let result = cached ?? built
        lock.unlock()
        return result
    }

    /// Drops the styled copy; the plain text stays available.
    func discardStyleCache() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}

nonisolated struct MarkdownListItem: Identifiable, @unchecked Sendable {
    let id: Int
    let checkbox: Bool?
    let sourceLine: Int?
    let blocks: [MarkdownBlock]
}

nonisolated struct MarkdownBlock: Identifiable, @unchecked Sendable {
    enum Kind: @unchecked Sendable {
        case heading(level: Int, text: LazyAttributed)
        case paragraph(text: LazyAttributed)
        case codeBlock(language: String?, code: String, highlighted: LazyAttributed)
        case blockQuote(blocks: [MarkdownBlock])
        case list(ordered: Bool, startIndex: Int, items: [MarkdownListItem])
        case table(alignments: [MarkdownTableAlignment], headers: [LazyAttributed], rows: [[LazyAttributed]])
        case image(url: URL, alt: String)
        case thematicBreak
    }

    let id: Int
    let kind: Kind
}

nonisolated struct FrontmatterField: Identifiable, Sendable {
    let id: Int
    let key: String
    let value: String
}

nonisolated struct LoadedNote: @unchecked Sendable {
    let url: URL
    let modificationDate: Date?
    let byteCount: Int
    let blocks: [MarkdownBlock]
    let headings: [NoteHeading]
    let frontmatter: [FrontmatterField]
    let tags: [String]
    let wordCount: Int
    let characterCount: Int
}

/// A freshly parsed note plus the source it was built from. The source is kept
/// so the render cache can hand it to the editor and to the tag scanner in the
/// background without a second read.
nonisolated struct RenderedNote: @unchecked Sendable {
    let note: LoadedNote
    let text: String
}
