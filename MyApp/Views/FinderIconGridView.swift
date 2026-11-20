import AppKit
import SwiftUI

/// Finder-like icon grid shown in the left bubble. Folders come first (the
/// caller sorts), single click selects, double click navigates or opens,
/// Return renames and items can be dragged out or dropped onto a folder.
struct FinderIconGridView: View {
    @Bindable var store: WorkspaceStore
    let nodes: [FileNode]
    let emptyMessage: String
    let currentDirectory: URL?
    @Binding var selectedURL: URL?
    let onOpen: (FileNode) -> Void

    @State private var renamingURL: URL?
    @State private var renameText = ""
    @State private var keyMonitor: Any?
    @State private var dropTargetURL: URL?
    @State private var isWindowActive = true
    @FocusState private var focusedRenameURL: URL?

    private let columns = [
        GridItem(.adaptive(minimum: 92, maximum: 104), spacing: 3, alignment: .top)
    ]

    var body: some View {
        Group {
            if nodes.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .contextMenu {
            backgroundMenu
        }
        .onAppear {
            isWindowActive = NSApp.isActive
            installReturnMonitor()
            FileIconProvider.shared.prefetch(nodes)
        }
        .onDisappear {
            removeReturnMonitor()
        }
        .onChange(of: store.pendingRenameURL) { _, _ in
            syncPendingRename()
        }
        .onChange(of: nodes.map(\.url)) { _, _ in
            syncPendingRename()
            FileIconProvider.shared.prefetch(nodes)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isWindowActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            isWindowActive = false
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(nodes) { node in
                    FinderIconCell(
                        node: node,
                        icon: icon(for: node),
                        isSelected: selectedURL == node.url,
                        isWindowActive: isWindowActive,
                        isRenaming: renamingURL == node.url,
                        renameText: $renameText,
                        renameFocus: $focusedRenameURL,
                        dropTargeted: dropTargetURL == node.url,
                        onSelect: {
                            selectedURL = node.url
                        },
                        onOpen: {
                            selectedURL = node.url
                            onOpen(node)
                        },
                        onBeginRename: {
                            beginRename(at: node.url)
                        },
                        onCommitRename: {
                            commitRename(for: node.url)
                        },
                        onCancelRename: {
                            cancelRename()
                        }
                    )
                    .onDrag {
                        NSItemProvider(contentsOf: node.url) ?? NSItemProvider()
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        dropTargetURL = nil
                        guard node.isDirectory else { return false }
                        return move(urls, into: node.url)
                    } isTargeted: { targeted in
                        guard node.isDirectory else { return }
                        if targeted {
                            dropTargetURL = node.url
                        } else if dropTargetURL == node.url {
                            dropTargetURL = nil
                        }
                    }
                    .contextMenu {
                        itemMenu(for: node)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text(emptyMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Menus

    @ViewBuilder
    private var backgroundMenu: some View {
        Button("Nouvelle note") {
            store.createNewNote(near: currentDirectory)
        }

        Button("Nouveau dossier") {
            store.createNewFolder(near: currentDirectory)
        }

        if let currentDirectory {
            Button("Révéler dans le Finder") {
                store.revealInFinder(url: currentDirectory)
            }
        }

        Divider()

        Button("Ouvrir un dossier…") {
            store.chooseFolder()
        }
    }

    @ViewBuilder
    private func itemMenu(for node: FileNode) -> some View {
        Button("Révéler dans le Finder") {
            store.revealInFinder(url: node.url)
        }

        if node.isDirectory {
            Button("Ouvrir") {
                onOpen(node)
            }
        }

        Divider()

        Button("Nouvelle note") {
            store.createNewNote(near: node.url)
        }

        Button("Nouveau dossier") {
            store.createNewFolder(near: node.url)
        }

        Divider()

        Button("Renommer") {
            beginRename(at: node.url)
        }

        Button("Dupliquer") {
            store.duplicateItem(at: node.url)
        }

        tagMenu(for: node.url)

        Divider()

        Button("Placer dans la corbeille") {
            store.trashItem(at: node.url)
        }
    }

    /// Finder's seven colours, identical to what the real Finder writes, with a
    /// check on the tag the file currently carries.
    @ViewBuilder
    private func tagMenu(for url: URL) -> some View {
        let active = store.finderTag(for: url)

        Menu("Étiquette") {
            ForEach(0...7, id: \.self) { label in
                Button {
                    store.setFinderTag(label, for: url)
                } label: {
                    if let dot = FileIconProvider.tagDotImage(for: label, checked: label == active) {
                        Label {
                            Text(WorkspaceStore.finderTagLabels[label])
                        } icon: {
                            Image(nsImage: dot)
                        }
                    } else {
                        Text(WorkspaceStore.finderTagLabels[label])
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func icon(for node: FileNode) -> NSImage {
        // Cached per kind: folders get their real icon a few ms after the first
        // paint (see FileIconProvider), files never touch the disk.
        FileIconProvider.shared.icon(for: node)
    }

    private func move(_ urls: [URL], into directory: URL) -> Bool {
        let sources = urls.filter { $0 != directory && $0.deletingLastPathComponent() != directory }
        guard !sources.isEmpty else { return false }
        for url in sources {
            store.moveItem(url, into: directory)
        }
        return true
    }

    private func beginRename(at url: URL) {
        guard let node = nodes.first(where: { $0.url == url }) else { return }
        selectedURL = url
        renameText = node.isDirectory ? node.name : (node.name as NSString).deletingPathExtension
        renamingURL = url
        // Focus after the field exists, then select the stem so the extension
        // (already stripped) is never part of the selection.
        DispatchQueue.main.async {
            focusedRenameURL = url
            DispatchQueue.main.async {
                guard NSApp.keyWindow?.firstResponder is NSTextView else { return }
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private func commitRename(for url: URL) {
        guard renamingURL == url else { return }
        let proposed = renameText
        renamingURL = nil
        focusedRenameURL = nil
        store.pendingRenameURL = nil
        store.renameItem(at: url, to: proposed)
    }

    private func cancelRename() {
        renamingURL = nil
        focusedRenameURL = nil
        store.pendingRenameURL = nil
    }

    private func syncPendingRename() {
        guard renamingURL == nil, let pending = store.pendingRenameURL else { return }
        guard nodes.contains(where: { $0.url == pending }) else { return }
        beginRename(at: pending)
    }

    // MARK: - Return key

    private func installReturnMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard renamingURL == nil,
                  let selectedURL,
                  event.keyCode == 36 || event.keyCode == 76,
                  !store.isEditing,
                  !store.isQuickSwitcherPresented,
                  !store.isSearchPresented,
                  !store.isGraphPresented,
                  NSApp.modalWindow == nil,
                  NSApp.mainWindow?.attachedSheet == nil,
                  NSApp.keyWindow === NSApp.mainWindow else {
                return event
            }

            // Never steal Return from an open field editor (search pill, rename…).
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField || responder is NSComboBox {
                return event
            }

            beginRename(at: selectedURL)
            return nil
        }
    }

    private func removeReturnMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

/// One Finder-style tile: a rounded translucent square behind the icon and an
/// accent pill behind the name, greying out when the window is inactive.
private struct FinderIconCell: View {
    let node: FileNode
    let icon: NSImage
    let isSelected: Bool
    let isWindowActive: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    let renameFocus: FocusState<URL?>.Binding
    let dropTargeted: Bool

    let onSelect: () -> Void
    let onOpen: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    @State private var isHovering = false

    private var iconBackground: Color {
        if isSelected {
            return isWindowActive ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.10)
        }
        return Color.white.opacity(isHovering ? 0.08 : 0)
    }

    private var nameBackground: Color {
        guard isSelected else { return .clear }
        return isWindowActive ? Color.accentColor : Color.primary.opacity(0.16)
    }

    private var nameForeground: Color {
        isSelected && isWindowActive ? .white : Color.primary.opacity(0.86)
    }

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 52, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(iconBackground)
                )
                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)

            if isRenaming {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1)
                    )
                    .focused(renameFocus, equals: node.url)
                    .onSubmit(onCommitRename)
                    .onExitCommand(perform: onCancelRename)
                    .frame(height: 20)
                    .frame(height: 28, alignment: .top)
            } else {
                Text(node.name)
                    .font(.system(size: 11))
                    .foregroundStyle(nameForeground)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.horizontal, 4)
                    .background(Capsule(style: .continuous).fill(nameBackground))
                    .frame(height: 28, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(isHovering && !isSelected ? 0.05 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(dropTargeted ? 0.8 : 0), lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .help(node.url.path)
        .accessibilityLabel(node.name)
    }
}
