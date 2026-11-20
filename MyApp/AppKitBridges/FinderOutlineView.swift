import AppKit
import QuickLookUI
import SwiftUI

struct FinderOutlineView: NSViewRepresentable {
    let nodes: [FileNode]
    let treeRevision: Int
    let isFiltering: Bool
    @Binding var selectedURL: URL?
    @Binding var pendingRenameURL: URL?
    let nodeLookup: (URL) -> FileNode?
    let onSelect: (URL?) -> Void
    let onRevealInFinder: (URL) -> Void
    let onNewNote: (URL?) -> Void
    let onNewFolder: (URL?) -> Void
    let onDuplicate: (URL) -> Void
    let onTrash: (URL) -> Void
    let onRename: (URL, String) -> Void
    /// Writes a Finder colour tag (0…7) on the item.
    let onSetFinderTag: (URL, Int) -> Void
    /// Asks the store for a folder's children when its row is expanded.
    let onExpand: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        // Let the Liquid Glass bubble show through the whole list.
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        let outlineView = FinderNSOutlineView()
        outlineView.coordinator = context.coordinator
        outlineView.headerView = nil
        outlineView.backgroundColor = .clear
        outlineView.rowSizeStyle = .small
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.indentationPerLevel = 14
        outlineView.autoresizesOutlineColumn = true
        outlineView.usesAlternatingRowBackgroundColors = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("NameColumn"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator

        scrollView.documentView = outlineView
        context.coordinator.outlineView = outlineView
        context.coordinator.reload(
            nodes: nodes,
            revision: treeRevision,
            isFiltering: isFiltering,
            selectedURL: selectedURL,
            pendingRenameURL: pendingRenameURL
        )

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.reloadIfNeeded(
            nodes: nodes,
            revision: treeRevision,
            isFiltering: isFiltering,
            selectedURL: selectedURL,
            pendingRenameURL: pendingRenameURL
        )
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
        var parent: FinderOutlineView
        weak var outlineView: FinderNSOutlineView?

        private var rootNodes: [FileNode] = []
        private var lastRevision: Int = -1
        private var isUpdatingSelection = false

        private var renamingURL: URL?
        private var renamingOriginalName: String?
        private var isCancellingRename = false
        private var scheduledRenameURL: URL?
        private var deferredReload: DeferredReload?
        var previewURL: URL?

        private struct DeferredReload {
            let nodes: [FileNode]
            let revision: Int
            let isFiltering: Bool
            let selectedURL: URL?
            let pendingRenameURL: URL?
        }

        init(parent: FinderOutlineView) {
            self.parent = parent
        }

        func reloadIfNeeded(
            nodes: [FileNode],
            revision: Int,
            isFiltering: Bool,
            selectedURL: URL?,
            pendingRenameURL: URL?
        ) {
            if revision != lastRevision {
                // Reloading mid-edit would tear down the field editor; keep the latest tree for later.
                guard renamingURL == nil else {
                    deferredReload = DeferredReload(
                        nodes: nodes,
                        revision: revision,
                        isFiltering: isFiltering,
                        selectedURL: selectedURL,
                        pendingRenameURL: pendingRenameURL
                    )
                    return
                }
                reload(
                    nodes: nodes,
                    revision: revision,
                    isFiltering: isFiltering,
                    selectedURL: selectedURL,
                    pendingRenameURL: pendingRenameURL
                )
            } else {
                syncSelection(to: selectedURL)
                if let pendingRenameURL {
                    scheduleRename(for: pendingRenameURL)
                }
            }
        }

        func reload(
            nodes: [FileNode],
            revision: Int,
            isFiltering: Bool,
            selectedURL: URL?,
            pendingRenameURL: URL?
        ) {
            guard let outlineView else { return }
            deferredReload = nil
            lastRevision = revision

            var expandedURLs = Set<URL>()
            for row in 0..<outlineView.numberOfRows {
                if let node = outlineView.item(atRow: row) as? FileNode,
                   node.isDirectory,
                   outlineView.isItemExpanded(node) {
                    expandedURLs.insert(node.url)
                }
            }

            rootNodes = nodes
            FileIconProvider.shared.prefetch(nodes)

            isUpdatingSelection = true
            outlineView.reloadData()

            if isFiltering {
                outlineView.expandItem(nil, expandChildren: true)
            } else {
                var row = 0
                while row < outlineView.numberOfRows {
                    if let node = outlineView.item(atRow: row) as? FileNode,
                       node.isDirectory,
                       expandedURLs.contains(node.url) {
                        outlineView.expandItem(node)
                    }
                    row += 1
                }
            }

            isUpdatingSelection = false
            syncSelection(to: selectedURL)

            if let pendingRenameURL {
                scheduleRename(for: pendingRenameURL)
            }
        }

        private func syncSelection(to targetURL: URL?) {
            guard let outlineView, !isUpdatingSelection else { return }
            isUpdatingSelection = true
            defer { isUpdatingSelection = false }

            guard let targetURL else {
                outlineView.deselectAll(nil)
                return
            }

            expandAncestors(of: targetURL)

            if let node = findVisibleOrExpandableNode(for: targetURL, in: rootNodes) {
                let row = outlineView.row(forItem: node)
                if row >= 0 && outlineView.selectedRow != row {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outlineView.scrollRowToVisible(row)
                }
            }
        }

        private func findVisibleOrExpandableNode(for targetURL: URL, in nodes: [FileNode]) -> FileNode? {
            for node in nodes {
                if node.url == targetURL { return node }
                if let found = findVisibleOrExpandableNode(for: targetURL, in: node.children) {
                    return found
                }
            }
            return parent.nodeLookup(targetURL)
        }

        private func expandAncestors(of targetURL: URL) {
            guard let outlineView else { return }
            var currentNodes = rootNodes
            while let parentFolder = currentNodes.first(where: {
                $0.isDirectory && targetURL.path.hasPrefix($0.url.path + "/")
            }) {
                outlineView.expandItem(parentFolder)
                currentNodes = parentFolder.children
            }
        }

        private func scheduleRename(for url: URL) {
            guard scheduledRenameURL != url else { return }
            scheduledRenameURL = url
            expandAncestors(of: url)

            // Deferred: writing observable state inside updateNSView triggers a SwiftUI warning.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduledRenameURL = nil
                guard let outlineView = self.outlineView,
                      let node = self.findVisibleOrExpandableNode(for: url, in: self.rootNodes) else {
                    return
                }
                let row = outlineView.row(forItem: node)
                guard row >= 0 else { return }
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
                self.beginRename(atRow: row)
                if self.renamingURL != nil {
                    self.parent.pendingRenameURL = nil
                }
            }
        }

        private func applyDeferredReload() {
            guard deferredReload != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let pending = self.deferredReload, pending.revision > self.lastRevision else { return }
                self.deferredReload = nil
                self.reload(
                    nodes: pending.nodes,
                    revision: pending.revision,
                    isFiltering: pending.isFiltering,
                    selectedURL: pending.selectedURL,
                    pendingRenameURL: pending.pendingRenameURL
                )
            }
        }

        func beginRename(atRow row: Int) {
            guard let outlineView,
                  row >= 0,
                  let node = outlineView.item(atRow: row) as? FileNode else {
                return
            }

            outlineView.scrollRowToVisible(row)
            guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? FinderRowCellView,
                  let nameField = cell.textField else {
                return
            }

            renamingURL = node.url
            renamingOriginalName = node.name
            isCancellingRename = false

            nameField.delegate = self
            nameField.isEditable = true
            nameField.isSelectable = true
            nameField.isBezeled = true
            nameField.bezelStyle = .roundedBezel
            nameField.drawsBackground = true
            nameField.backgroundColor = .textBackgroundColor

            outlineView.window?.makeFirstResponder(nameField)

            if let editor = nameField.currentEditor() {
                if !node.isDirectory {
                    let stemLength = (node.name as NSString).deletingPathExtension.utf16.count
                    editor.selectedRange = NSRange(location: 0, length: stemLength)
                } else {
                    editor.selectAll(nil)
                }
            }
        }

        // MARK: - NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? FileNode else {
                return rootNodes.count
            }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? FileNode else {
                return rootNodes[index]
            }
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? FileNode else { return false }
            return node.isDirectory
        }

        // MARK: - NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileNode else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("FinderRowCell")
            let cell: FinderRowCellView
            if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? FinderRowCellView {
                cell = reused
            } else {
                cell = FinderRowCellView()
                cell.identifier = identifier
            }

            // Never resize the cached NSImage: it is shared with the icon grid
            // and other rows, and mutating its size would rasterise every use
            // from a 16 pt copy. The image view scales the real Finder artwork.
            cell.imageView?.image = FileIconProvider.shared.icon(for: node)
            cell.textField?.stringValue = node.name
            cell.textField?.isEditable = false
            cell.textField?.isSelectable = false
            cell.textField?.isBezeled = false
            cell.textField?.drawsBackground = false
            return cell
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
            parent.onExpand(node.url)
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingSelection, let outlineView else { return }
            let row = outlineView.selectedRow
            let url = (row >= 0 ? outlineView.item(atRow: row) as? FileNode : nil)?.url
            if parent.selectedURL != url {
                parent.selectedURL = url
            }
            parent.onSelect(url)
        }

        // MARK: - NSTextFieldDelegate (Inline Rename)

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }

            textField.isEditable = false
            textField.isSelectable = false
            textField.isBezeled = false
            textField.drawsBackground = false

            let targetURL = renamingURL
            let originalName = renamingOriginalName
            let cancelled = isCancellingRename

            renamingURL = nil
            renamingOriginalName = nil
            isCancellingRename = false

            if let outlineView {
                outlineView.window?.makeFirstResponder(outlineView)
            }

            applyDeferredReload()

            if cancelled {
                if let originalName {
                    textField.stringValue = originalName
                }
                return
            }

            guard let targetURL else { return }
            let proposed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if proposed.isEmpty || proposed.contains("/") || proposed.contains(":") {
                if let originalName {
                    textField.stringValue = originalName
                }
                return
            }

            parent.onRename(targetURL, proposed)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                isCancellingRename = true
                if let outlineView {
                    outlineView.window?.makeFirstResponder(outlineView)
                }
                return true
            }
            return false
        }

        // MARK: - Context Menu Actions

        func buildContextMenu(for targetURL: URL?) -> NSMenu {
            let menu = NSMenu()

            if let targetURL {
                let revealItem = NSMenuItem(
                    title: "Révéler dans le Finder",
                    action: #selector(menuRevealInFinder(_:)),
                    keyEquivalent: ""
                )
                revealItem.target = self
                revealItem.representedObject = targetURL
                menu.addItem(revealItem)
                menu.addItem(.separator())
            }

            let newNoteItem = NSMenuItem(
                title: "Nouvelle note",
                action: #selector(menuNewNote(_:)),
                keyEquivalent: ""
            )
            newNoteItem.target = self
            newNoteItem.representedObject = targetURL
            menu.addItem(newNoteItem)

            let newFolderItem = NSMenuItem(
                title: "Nouveau dossier",
                action: #selector(menuNewFolder(_:)),
                keyEquivalent: ""
            )
            newFolderItem.target = self
            newFolderItem.representedObject = targetURL
            menu.addItem(newFolderItem)

            if let targetURL {
                menu.addItem(.separator())

                let renameItem = NSMenuItem(
                    title: "Renommer",
                    action: #selector(menuRename(_:)),
                    keyEquivalent: ""
                )
                renameItem.target = self
                renameItem.representedObject = targetURL
                menu.addItem(renameItem)

                let duplicateItem = NSMenuItem(
                    title: "Dupliquer",
                    action: #selector(menuDuplicate(_:)),
                    keyEquivalent: ""
                )
                duplicateItem.target = self
                duplicateItem.representedObject = targetURL
                menu.addItem(duplicateItem)

                menu.addItem(tagMenuItem(for: targetURL))

                menu.addItem(.separator())

                let trashItem = NSMenuItem(
                    title: "Placer dans la corbeille",
                    action: #selector(menuTrash(_:)),
                    keyEquivalent: ""
                )
                trashItem.target = self
                trashItem.representedObject = targetURL
                menu.addItem(trashItem)
            }

            return menu
        }

        /// Finder's colour dots, with a check on the one already on disk.
        private func tagMenuItem(for targetURL: URL) -> NSMenuItem {
            let active = (try? targetURL.resourceValues(forKeys: [.labelNumberKey]))?.labelNumber ?? 0
            let item = NSMenuItem(title: "Étiquette", action: nil, keyEquivalent: "")
            let submenu = NSMenu()

            for label in 0...7 {
                let entry = NSMenuItem(
                    title: WorkspaceStore.finderTagLabels[label],
                    action: #selector(menuSetFinderTag(_:)),
                    keyEquivalent: ""
                )
                entry.target = self
                entry.representedObject = targetURL
                entry.tag = label
                entry.state = label == active ? .on : .off
                entry.image = FileIconProvider.tagDotImage(for: label, checked: label == active)
                submenu.addItem(entry)
            }

            item.submenu = submenu
            return item
        }

        @objc private func menuRename(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            parent.pendingRenameURL = url
            scheduleRename(for: url)
        }

        @objc private func menuSetFinderTag(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            parent.onSetFinderTag(url, sender.tag)
        }

        @objc private func menuRevealInFinder(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            parent.onRevealInFinder(url)
        }

        @objc private func menuNewNote(_ sender: NSMenuItem) {
            parent.onNewNote(sender.representedObject as? URL)
        }

        @objc private func menuNewFolder(_ sender: NSMenuItem) {
            parent.onNewFolder(sender.representedObject as? URL)
        }

        @objc private func menuDuplicate(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            parent.onDuplicate(url)
        }

        @objc private func menuTrash(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            parent.onTrash(url)
        }
    }
}

extension FinderOutlineView.Coordinator: QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }
}

final class FinderNSOutlineView: NSOutlineView {
    weak var coordinator: FinderOutlineView.Coordinator?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn,
           selectedRow >= 0,
           !(window?.firstResponder is NSTextView) {
            coordinator?.beginRename(atRow: selectedRow)
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 49, modifiers.isEmpty, selectedRow >= 0 {
            toggleQuickLook()
            return
        }

        super.keyDown(with: event)
    }

    func toggleQuickLook() {
        guard selectedRow >= 0,
              let node = item(atRow: selectedRow) as? FileNode,
              let coordinator,
              let panel = QLPreviewPanel.shared() else {
            return
        }

        coordinator.previewURL = node.url
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        selectedRow >= 0
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = coordinator
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)

        let targetURL: URL?
        if clickedRow >= 0, let node = item(atRow: clickedRow) as? FileNode {
            if !isRowSelected(clickedRow) {
                selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }
            targetURL = node.url
        } else {
            targetURL = nil
        }

        return coordinator?.buildContextMenu(for: targetURL)
    }
}

private final class FinderRowCellView: NSTableCellView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true

        addSubview(icon)
        addSubview(label)

        imageView = icon
        textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
