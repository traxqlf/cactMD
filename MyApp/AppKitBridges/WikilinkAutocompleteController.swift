import AppKit

final class WikilinkSuggestionsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var items: [NoteReference] = []
    var onCommit: ((NoteReference) -> Void)?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Suggestion"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 26
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.documentView = tableView
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func update(items: [NoteReference]) {
        self.items = items
        tableView.reloadData()
        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
        preferredContentSize = NSSize(width: 320, height: CGFloat(min(items.count, 8)) * 26 + 8)
    }

    var currentItem: NoteReference? {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return nil }
        return items[row]
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = max(tableView.selectedRow, 0)
        let next = min(max(current + delta, 0), items.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let item = items[row]

        let cell: NSTableCellView
        let identifier = NSUserInterfaceItemIdentifier("WikilinkSuggestionCell")
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingMiddle
            label.usesSingleLineMode = true
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        let attributed = NSMutableAttributedString(
            string: item.name,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor
            ]
        )
        if !item.folder.isEmpty {
            attributed.append(
                NSAttributedString(
                    string: "  \(item.folder)",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                )
            )
        }
        cell.textField?.attributedStringValue = attributed
        return cell
    }

    @objc private func rowClicked() {
        guard let item = currentItem else { return }
        onCommit?(item)
    }
}

final class WikilinkAutocompleteController {
    private let popover = NSPopover()
    private let listViewController = WikilinkSuggestionsViewController()
    private weak var textView: MarkdownTextView?
    private var contextRange: NSRange?

    var isVisible: Bool { popover.isShown }

    init(textView: MarkdownTextView) {
        self.textView = textView
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = listViewController
        popover.contentSize = NSSize(width: 320, height: 140)

        listViewController.onCommit = { [weak self] note in
            self?.insert(note)
        }
    }

    func update(query: String, contextRange: NSRange) {
        guard let textView, let suggestions = textView.suggestionProvider?() else {
            dismiss()
            return
        }

        let normalized = query.lowercased()
        let filtered = suggestions
            .filter {
                normalized.isEmpty
                    || $0.name.lowercased().contains(normalized)
                    || $0.relativePath.lowercased().contains(normalized)
            }
            .prefix(20)

        guard !filtered.isEmpty else {
            dismiss()
            return
        }

        self.contextRange = contextRange
        listViewController.update(items: Array(filtered))

        if !popover.isShown {
            guard let window = textView.window else { return }
            let screenRect = textView.firstRect(
                forCharacterRange: NSRange(location: contextRange.location, length: 0),
                actualRange: nil
            )
            let windowRect = window.convertFromScreen(screenRect)
            let viewRect = textView.convert(windowRect, from: nil)
            popover.show(relativeTo: viewRect, of: textView, preferredEdge: .minY)
            textView.window?.makeFirstResponder(textView)
        }
    }

    func moveSelection(by delta: Int) {
        listViewController.moveSelection(by: delta)
    }

    func acceptSelection() {
        guard let item = listViewController.currentItem else {
            dismiss()
            return
        }
        insert(item)
    }

    func dismiss() {
        contextRange = nil
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    private func insert(_ note: NoteReference) {
        guard let textView, let range = contextRange else { return }
        contextRange = nil
        if popover.isShown {
            popover.performClose(nil)
        }
        textView.insertText("[[\(note.name)]]", replacementRange: range)
    }
}
