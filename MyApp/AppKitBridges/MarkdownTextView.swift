import AppKit

final class MarkdownTextView: NSTextView {
    var suggestionProvider: (() -> [NoteReference])?
    var mediaImporter: ((MediaPayload) -> String?)?
    /// Bubbles a contextual ✨ action up to the store, which opens the popover.
    var selectionAIAction: ((NoteAISelectionAction, String) -> Void)?
    /// Opens `[[…]]` clicked in the Live Preview, like the reader does.
    var wikilinkOpenHandler: ((String) -> Void)?
    private(set) var wikilinkAutocomplete: WikilinkAutocompleteController?
    private let liveStyler = MarkdownLiveStyler()
    private var isFocusMode = false
    private var focusObservers: [NSObjectProtocol] = []

    private static let listPrefixRegex = try? NSRegularExpression(
        pattern: #"^([ \t]*)([-*+])([ \t]+)(\[[ xX]\][ \t]+)?"#
    )
    private static let orderedPrefixRegex = try? NSRegularExpression(
        pattern: #"^([ \t]*)(\d{1,9})([.)])([ \t]+)"#
    )

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
    }

    func enableWikilinkAutocomplete() {
        guard wikilinkAutocomplete == nil else { return }
        wikilinkAutocomplete = WikilinkAutocompleteController(textView: self)
    }

    /// Live Preview: styles Markdown while typing and masks the delimiters the
    /// caret is not on. Only attributes change, never `string`.
    func enableLivePreview() {
        liveStyler.install(on: self)
    }

    func disableLivePreview() {
        liveStyler.detach()
        stopFocusScrolling()
        isFocusMode = false
    }

    /// Focus/typewriter mode: dimmed surroundings and the edited line kept in
    /// the middle of the viewport. Styling only, never a text change.
    func setFocusMode(_ enabled: Bool) {
        guard isFocusMode != enabled else {
            liveStyler.setFocusMode(enabled)
            return
        }
        isFocusMode = enabled
        liveStyler.setFocusMode(enabled)

        if enabled {
            observeFocusScrolling()
            DispatchQueue.main.async { [weak self] in
                self?.centerCaretLine(animated: false)
            }
        } else {
            stopFocusScrolling()
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.clickCount == 1, flags.isEmpty else {
            super.mouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)

        // A rendered `[[link]]` behaves like a link: clicking it navigates
        // instead of dropping the caret inside the (masked) syntax.
        if let target = liveStyler.wikilinkTarget(atCharacterIndex: index) {
            window?.makeFirstResponder(self)
            wikilinkOpenHandler?(target)
            return
        }

        if let checkbox = checkboxRange(at: index) {
            toggleCheckbox(in: checkbox)
            return
        }

        super.mouseDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        refreshWikilinkAutocomplete()
    }

    override func keyDown(with event: NSEvent) {
        if let autocomplete = wikilinkAutocomplete, autocomplete.isVisible {
            switch event.keyCode {
            case 125:
                autocomplete.moveSelection(by: 1)
                return
            case 126:
                autocomplete.moveSelection(by: -1)
                return
            case 36, 76, 48:
                autocomplete.acceptSelection()
                return
            case 53:
                autocomplete.dismiss()
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command,
              let characters = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        switch characters {
        case "b":
            wrapSelection(with: "**")
            return true
        case "i":
            wrapSelection(with: "*")
            return true
        case "e":
            wrapSelection(with: "`")
            return true
        case "k":
            insertMarkdownLink()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: - Image paste & drop

    override func paste(_ sender: Any?) {
        if importImages(from: .general) { return }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {            canAcceptImages(from: sender.draggingPasteboard)
            ? .copy
            : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {            canAcceptImages(from: sender.draggingPasteboard)
            ? .copy
            : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = imageFileURLs(from: sender.draggingPasteboard)
        let data = urls.isEmpty ? imageData(from: sender.draggingPasteboard) : nil
        guard !urls.isEmpty || data != nil else {
            return super.performDragOperation(sender)
        }

        let point = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        for url in urls {
            if let markdown = mediaImporter?(.file(url)) {
                insertImageMarkdown(markdown)
            }
        }
        if let data {
            let name = "image-\(UUID().uuidString.prefix(6))"
            if let markdown = mediaImporter?(.data(data, suggestedName: String(name))) {
                insertImageMarkdown(markdown)
            }
        }
        return true
    }

    private func imageData(from pasteboard: NSPasteboard) -> Data? {
        guard let type = pasteboard.availableType(from: [.png, .tiff]) else { return nil }
        guard let data = pasteboard.data(forType: type), NSImage(data: data) != nil else { return nil }
        return data
    }

    private func importImages(from pasteboard: NSPasteboard) -> Bool {
        let urls = imageFileURLs(from: pasteboard)
        if !urls.isEmpty {
            for url in urls {
                if let markdown = mediaImporter?(.file(url)) {
                    insertImageMarkdown(markdown)
                }
            }
            return true
        }

        // Plain text paste must keep its normal behaviour; only raw image data is imported.
        guard pasteboard.string(forType: .string) == nil,
              let type = pasteboard.availableType(from: [.png, .tiff]),
              let data = pasteboard.data(forType: type),
              NSImage(data: data) != nil else {
            return false
        }

        let name = "image-\(UUID().uuidString.prefix(6))"
        if let markdown = mediaImporter?(.data(data, suggestedName: String(name))) {
            insertImageMarkdown(markdown)
        }
        return true
    }

    private func canAcceptImages(from pasteboard: NSPasteboard) -> Bool {
        if !imageFileURLs(from: pasteboard).isEmpty { return true }
        return imageData(from: pasteboard) != nil && pasteboard.string(forType: .string) == nil
    }

    private func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.filter(MediaLibrary.isImageFile)
    }

    private func insertImageMarkdown(_ markdown: String) {
        let nsText = string as NSString
        let cursor = selectedRange().location
        var insertion = markdown
        if cursor > 0, nsText.character(at: cursor - 1) != 10 {
            insertion = "\n" + insertion
        }
        if cursor < nsText.length, nsText.character(at: cursor) != 10 {
            insertion += "\n"
        }
        guard shouldChangeText(in: selectedRange(), replacementString: insertion) else { return }
        insertText(insertion, replacementRange: selectedRange())
    }

    override func insertNewline(_ sender: Any?) {
        let nsText = string as NSString
        let cursor = selectedRange().location
        guard cursor <= nsText.length else {
            super.insertNewline(sender)
            return
        }

        let lineRange = nsText.lineRange(for: NSRange(location: cursor, length: 0))
        let line = nsText.substring(with: lineRange) as NSString
        let fullRange = NSRange(location: 0, length: line.length)

        if continueOrderedList(in: line, lineRange: lineRange) { return }

        guard let regex = Self.listPrefixRegex,
              let match = regex.firstMatch(in: line as String, range: fullRange),
              match.range.location == 0 else {
            super.insertNewline(sender)
            return
        }

        let content = line.substring(from: match.range.length)
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            insertText("", replacementRange: NSRange(location: lineRange.location, length: match.range.length))
            return
        }

        let indent = line.substring(with: match.range(at: 1))
        let bullet = line.substring(with: match.range(at: 2))
        let checkboxRange = match.range(at: 4)
        let checkbox = checkboxRange.location == NSNotFound ? "" : "[ ] "

        let continuation = "\n\(indent)\(bullet) \(checkbox)"
        insertText(continuation, replacementRange: selectedRange())
    }

    /// `3. ` becomes `4. `; an empty `2. ` is removed so Enter leaves the list.
    private func continueOrderedList(in line: NSString, lineRange: NSRange) -> Bool {
        guard let regex = Self.orderedPrefixRegex,
              let match = regex.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)),
              match.range.location == 0 else {
            return false
        }

        let content = line.substring(from: match.range.length)
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            insertText("", replacementRange: NSRange(location: lineRange.location, length: match.range.length))
            return true
        }

        let indent = line.substring(with: match.range(at: 1))
        let number = Int(line.substring(with: match.range(at: 2))) ?? 1
        let delimiter = line.substring(with: match.range(at: 3))
        insertText("\n\(indent)\(number + 1)\(delimiter) ", replacementRange: selectedRange())
        return true
    }

    private func wrapSelection(with marker: String) {
        let range = selectedRange()
        let nsText = string as NSString
        let selected = nsText.substring(with: range)
        let replacement = marker + selected + marker

        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        insertText(replacement, replacementRange: range)
        setSelectedRange(
            NSRange(location: range.location + marker.utf16.count, length: selected.utf16.count)
        )
    }

    private func insertMarkdownLink() {
        let range = selectedRange()
        let selected = (string as NSString).substring(with: range)
        let placeholder = "url"
        let replacement = "[\(selected)](\(placeholder))"

        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        insertText(replacement, replacementRange: range)
        // The destination is selected, so typing replaces it immediately.
        setSelectedRange(NSRange(location: range.location + 3 + selected.utf16.count, length: placeholder.utf16.count))
    }

    // MARK: - Contextual assistant

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard selectionContainsText else { return menu }

        guard let menu else { return nil }
        let assistant = NSMenu(title: "✨ Assistant IA")

        for action in NoteAISelectionAction.allCases {
            let item = NSMenuItem(
                title: action.menuTitle,
                action: #selector(performSelectionAIAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = action
            assistant.addItem(item)
        }

        let item = NSMenuItem(title: "✨ Assistant IA", action: nil, keyEquivalent: "")
        item.submenu = assistant
        if menu.items.last?.isSeparatorItem == false {
            menu.addItem(.separator())
        }
        menu.addItem(item)
        return menu
    }

    private var selectionContainsText: Bool {
        let range = selectedRange()
        guard range.length > 0 else { return false }
        let text = (string as NSString).substring(with: range)
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func performSelectionAIAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? NoteAISelectionAction else { return }
        let range = selectedRange()
        guard range.length > 0 else { return }
        let text = (string as NSString).substring(with: range)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        selectionAIAction?(action, text)
    }

    private func refreshWikilinkAutocomplete() {
        guard let autocomplete = wikilinkAutocomplete else { return }
        guard let context = wikilinkContext() else {
            autocomplete.dismiss()
            return
        }
        autocomplete.update(query: context.query, contextRange: context.range)
    }

    private func wikilinkContext() -> (range: NSRange, query: String)? {
        let cursor = selectedRange().location
        let nsText = string as NSString
        guard cursor <= nsText.length else { return nil }

        let lineRange = nsText.lineRange(for: NSRange(location: cursor, length: 0))
        let beforeLength = cursor - lineRange.location
        guard beforeLength >= 2 else { return nil }

        let before = nsText.substring(
            with: NSRange(location: lineRange.location, length: beforeLength)
        ) as NSString
        let opening = before.range(of: "[[", options: .backwards)
        guard opening.location != NSNotFound else { return nil }

        let queryStart = opening.location + 2
        guard queryStart <= before.length else { return nil }
        let query = before.substring(from: queryStart)
        guard !query.contains("]]"), !query.contains("["), !query.contains("|") else { return nil }

        let start = lineRange.location + opening.location
        return (NSRange(location: start, length: cursor - start), query)
    }

    // MARK: - Task checkboxes

    /// Character range of the `[ ]` marker under `index`, if the click landed
    /// on a task list item.
    private func checkboxRange(at index: Int) -> NSRange? {
        let nsText = string as NSString
        guard nsText.length > 0 else { return nil }
        let location = min(max(index, 0), nsText.length - 1)
        let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
        let line = nsText.substring(with: lineRange) as NSString

        guard let regex = Self.listPrefixRegex,
              let match = regex.firstMatch(
                in: line as String,
                range: NSRange(location: 0, length: line.length)
              ),
              match.range(at: 4).location != NSNotFound else {
            return nil
        }

        let marker = NSRange(location: match.range(at: 4).location, length: 3)
        let absolute = NSRange(location: lineRange.location + marker.location, length: marker.length)
        guard index >= absolute.location, index < NSMaxRange(absolute) else { return nil }
        return absolute
    }

    /// Native edit, so ⌘Z restores the previous state and the autosave fires.
    private func toggleCheckbox(in range: NSRange) {
        let nsText = string as NSString
        guard NSMaxRange(range) <= nsText.length else { return }
        let checked = nsText.substring(with: range).lowercased().contains("x")
        let replacement = checked ? "[ ]" : "[x]"
        let caret = selectedRange()

        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        insertText(replacement, replacementRange: range)
        setSelectedRange(caret)
    }

    // MARK: - Scrolling

    /// Scrolls the editor to a heading found by `MarkdownHeadingScanner`.
    func scrollToHeading(offset: Int) {
        let nsText = string as NSString
        guard nsText.length > 0, offset >= 0, offset < nsText.length else { return }
        guard let rect = layoutRect(forCharacterRange: NSRange(location: offset, length: 0)) else { return }
        scroll(toDocumentY: rect.minY - 24, animated: true)
        setSelectedRange(NSRange(location: offset, length: 0))
    }

    /// Keeps the line being edited vertically centred (typewriter scrolling).
    func centerCaretLine(animated: Bool = true) {
        guard isFocusMode else { return }
        let nsText = string as NSString
        guard nsText.length > 0 else { return }
        let caret = min(max(selectedRange().location, 0), nsText.length - 1)
        guard let rect = layoutRect(forCharacterRange: NSRange(location: caret, length: 1)) else { return }
        scroll(toDocumentY: rect.midY - visibleHeight / 2, animated: animated)
    }

    private var visibleHeight: CGFloat {
        enclosingScrollView?.contentView.bounds.height ?? bounds.height
    }

    private func layoutRect(forCharacterRange range: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: range,
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 || range.length == 0 else { return nil }
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.y += textContainerInset.height
        return rect
    }

    private func scroll(toDocumentY proposed: CGFloat, animated: Bool) {
        guard let scrollView = enclosingScrollView else { return }
        let clipView = scrollView.contentView
        let usedHeight = textContainer.flatMap { container in
            layoutManager?.usedRect(for: container).height
        } ?? 0
        let documentHeight = max(usedHeight + textContainerInset.height * 2, clipView.bounds.height)
        let target = min(
            max(proposed, 0),
            max(0, documentHeight - clipView.bounds.height)
        )
        guard abs(clipView.bounds.origin.y - target) > 0.5 else { return }

        let origin = NSPoint(x: clipView.bounds.origin.x, y: target)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.allowsImplicitAnimation = true
                clipView.animator().setBoundsOrigin(origin)
            }
            scrollView.reflectScrolledClipView(clipView)
        } else {
            clipView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    private func observeFocusScrolling() {
        guard focusObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let queue = OperationQueue.main

        focusObservers.append(center.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: self,
            queue: queue
        ) { [weak self] _ in
            self?.centerCaretLine()
        })

        focusObservers.append(center.addObserver(
            forName: NSText.didChangeNotification,
            object: self,
            queue: queue
        ) { [weak self] _ in
            self?.centerCaretLine()
        })
    }

    private func stopFocusScrolling() {
        guard !focusObservers.isEmpty else { return }
        let center = NotificationCenter.default
        focusObservers.forEach(center.removeObserver)
        focusObservers.removeAll()
    }
}
