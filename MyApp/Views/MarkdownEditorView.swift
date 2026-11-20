import AppKit
import SwiftUI

struct MarkdownEditorView: NSViewRepresentable {
    let store: WorkspaceStore

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = EditorScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.scrollerStyle = .overlay

        let textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 640))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.registerForDraggedTypes([.fileURL])
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 5
        paragraphStyle.paragraphSpacing = 2
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]

        textView.string = store.editorText
        textView.enableLivePreview()
        textView.delegate = context.coordinator
        textView.selectionAIAction = { [weak store] action, text in
            store?.requestAISelection(action, text: text)
        }
        // The assistant edits the live buffer, so ⌘Z and the autosave keep
        // working exactly as if the user had typed the change.
        store.replaceEditorSelection = { [weak textView] replacement in
            guard let textView else { return }
            let range = textView.selectedRange()
            guard range.length > 0 else { return }
            textView.window?.makeFirstResponder(textView)
            guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
            textView.insertText(replacement, replacementRange: range)
        }
        store.insertBelowEditorSelection = { [weak textView] insertion in
            guard let textView else { return }
            let nsText = textView.string as NSString
            let range = textView.selectedRange()
            let location = min(range.location + range.length, nsText.length)

            var text = insertion
            if location > 0, nsText.character(at: location - 1) != 10 {
                text = "\n" + text
            }
            if location < nsText.length, nsText.character(at: location) != 10 {
                text += "\n"
            }

            let target = NSRange(location: location, length: 0)
            textView.window?.makeFirstResponder(textView)
            guard textView.shouldChangeText(in: target, replacementString: text) else { return }
            textView.insertText(text, replacementRange: target)
            textView.setSelectedRange(NSRange(location: location + text.utf16.count, length: 0))
        }
        textView.enableWikilinkAutocomplete()
        textView.suggestionProvider = { [weak store] in store?.allNotes ?? [] }
        textView.wikilinkOpenHandler = { [weak store] name in
            store?.requestWikilinkOpen(name)
        }
        textView.setFocusMode(store.isFocusMode)
        textView.mediaImporter = { [weak store] payload in
            guard let store, let noteURL = store.openNoteURL else { return nil }
            do {
                let relativePath = try MediaLibrary.save(
                    payload,
                    noteDirectory: noteURL.deletingLastPathComponent()
                )
                return "![](\(relativePath))"
            } catch {
                store.errorMessage = error.localizedDescription
                return nil
            }
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView

        scrollView.onLayout = { [weak textView, weak store] width in
            guard let textView else { return }
            let inset = Self.textInset(for: width, sidebarVisible: store?.isSidebarVisible ?? true)
            if textView.textContainerInset.width != inset {
                textView.textContainerInset = NSSize(width: inset, height: 28)
            }
        }

        DispatchQueue.main.async {
            let width = scrollView.contentSize.width
            textView.textContainerInset = NSSize(
                width: Self.textInset(for: width, sidebarVisible: store.isSidebarVisible),
                height: 28
            )
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    /// Same reading column rule as the rendered page: 750 pt normally, then the
    /// freed width up to 960 pt once the Finder is hidden.
    private static func textInset(for width: CGFloat, sidebarVisible: Bool) -> CGFloat {
        let column = sidebarVisible ? 750 : min(960, max(700, width - 360))
        return max(36, (width - column) / 2)
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.store = store
        context.coordinator.textView?.suggestionProvider = { [weak store] in store?.allNotes ?? [] }

        if store.isQuickSwitcherPresented || store.isTemplatePickerPresented {
            context.coordinator.textView?.wikilinkAutocomplete?.dismiss()
        }

        context.coordinator.textView?.setFocusMode(store.isFocusMode)

        if let scrollView = nsView as? EditorScrollView,
           let textView = context.coordinator.textView {
            let width = scrollView.contentSize.width
            // Hiding the Finder widens the editing column exactly like the
            // reading page, so text and header stay on one vertical axis.
            let inset = Self.textInset(for: width, sidebarVisible: store.isSidebarVisible)
            if textView.textContainerInset.width != inset {
                textView.textContainerInset = NSSize(width: inset, height: 28)
            }

            // The buffer can arrive after the view exists: ⌘⇧E on a note the
            // cache does not hold yet fills it from a background read. Pushing
            // it here keeps typing away from the main-thread file read.
            if textView.string != store.editorText, !textView.hasMarkedText() {
                textView.string = store.editorText
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.textView?.wikilinkAutocomplete?.dismiss()
        coordinator.textView?.disableLivePreview()
        coordinator.textView?.delegate = nil
        coordinator.store.replaceEditorSelection = nil
        coordinator.store.insertBelowEditorSelection = nil
        coordinator.store.editorSelectionPreview = ""
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var store: WorkspaceStore
        weak var textView: MarkdownTextView?
        /// Outline headings of the live buffer, rebuilt only when the text changes.
        private var headingCache: [MarkdownHeadingScanner.Heading] = []
        private var headingCacheNeedsRefresh = true

        init(store: WorkspaceStore) {
            self.store = store
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleFocusEditor),
                name: .systemMDFocusEditor,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleScrollToHeading(_:)),
                name: .systemMDScrollEditorToHeading,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func handleFocusEditor() {
            guard let textView, let window = textView.window else { return }
            window.makeFirstResponder(textView)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else { return }
            store.editorText = textView.string
            headingCacheNeedsRefresh = true
        }

        /// Outline → editor: the clicked heading is located in the live buffer
        /// (not in the last saved file) so the jump is exact even mid-typing.
        @objc private func handleScrollToHeading(_ notification: Notification) {
            guard let blockID = notification.object as? Int, let textView else { return }
            guard let headings = store.loadedNote?.headings,
                  let index = headings.firstIndex(where: { $0.id == blockID }) else {
                return
            }
            let target = headings[index]
            let scanned = MarkdownHeadingScanner.headings(in: textView.string)
            guard !scanned.isEmpty else { return }

            let resolved: MarkdownHeadingScanner.Heading?
            if index < scanned.count,
               scanned[index].level == target.level,
               scanned[index].title == target.title {
                resolved = scanned[index]
            } else {
                resolved = scanned.first { $0.level == target.level && $0.title == target.title }
            }
            guard let resolved else { return }

            textView.window?.makeFirstResponder(textView)
            textView.scrollToHeading(offset: resolved.offset)
        }

        /// Keeps the outline highlight on the section holding the caret.
        private func updateActiveHeading(in textView: MarkdownTextView) {
            if headingCacheNeedsRefresh {
                headingCache = MarkdownHeadingScanner.headings(in: textView.string)
                headingCacheNeedsRefresh = false
            }
            guard !headingCache.isEmpty,
                  let index = MarkdownHeadingScanner.headingIndex(
                    atOrBefore: textView.selectedRange().location,
                    in: headingCache
                  ),
                  let headings = store.loadedNote?.headings,
                  index < headings.count else {
                if store.activeHeadingID != nil { store.activeHeadingID = nil }
                return
            }

            let id = headings[index].id
            if store.activeHeadingID != id { store.activeHeadingID = id }
        }

        /// Keeps the assistant popover in sync with what the user highlights.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else { return }
            updateActiveHeading(in: textView)

            let range = textView.selectedRange()
            guard range.length > 0, range.length <= 4_000 else {
                store.editorSelectionPreview = ""
                return
            }
            let text = (textView.string as NSString).substring(with: range)
            store.editorSelectionPreview = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ? "" : text
        }
    }
}

private final class EditorScrollView: NSScrollView {
    var onLayout: ((CGFloat) -> Void)?

    override func layout() {
        super.layout()
        onLayout?(contentSize.width)
    }
}
