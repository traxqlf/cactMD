import AppKit
import SwiftUI

enum FinderDisplayMode: String {
    case icons
    case tree
}

private enum FinderSidebarTab {
    case folder
    case recents
}

/// Left-hand Finder panel, detached from the window edges as a floating
/// "Liquid Glass" bubble. Icon grid and outline share the same file actions.
struct LeftFinderBubbleView: View {
    @Bindable var store: WorkspaceStore
    @Binding var mode: FinderDisplayMode
    @Binding var directory: URL?
    /// Incremented by ContentView when ⌘F should reveal the search pill.
    let searchFocusToken: Int

    @State private var isSearchExpanded = false
    @State private var iconSelection: URL?
    @State private var sidebarTab: FinderSidebarTab = .folder
    @FocusState private var isSearchFocused: Bool

    private var currentDirectory: URL? {
        directory ?? store.rootURL
    }

    private var isFiltering: Bool {
        !store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || store.activeTagFilter != nil
    }

    private var canGoUp: Bool {
        guard let root = store.rootURL, let current = currentDirectory else { return false }
        return current != root && current.path.hasPrefix(root.path + "/")
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if store.rootURL != nil {
                tabSelector
            }

            if isSearchExpanded {
                searchPill
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let tag = store.activeTagFilter {
                tagChip(tag)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            glassDivider

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let root = store.rootURL, sidebarTab == .folder {
                glassDivider
                FinderPathBarView(
                    rootURL: root,
                    currentURL: currentDirectory ?? root,
                    onNavigate: navigate
                )
            }
        }
        .background(LiquidGlassBubbleBackground())
        .onAppear {
            if let root = store.rootURL {
                FileIconProvider.shared.prefetchDirectoryURLs([root])
            }
        }
        .onChange(of: store.rootURL) { _, newRoot in
            directory = nil
            iconSelection = nil
            isSearchExpanded = false
            if !store.searchQuery.isEmpty {
                store.searchQuery = ""
            }
            if let newRoot {
                FileIconProvider.shared.prefetchDirectoryURLs([newRoot])
            }
        }
        .onChange(of: store.treeRevision) { _, _ in
            guard let current = directory, current != store.rootURL else { return }
            if store.node(for: current) == nil {
                directory = nil
            }
        }
        .onChange(of: directory) { _, newValue in
            // Opening a folder in the icon grid reads its contents on demand.
            if let newValue {
                store.ensureChildrenLoaded(for: newValue)
            }
        }
        .onChange(of: searchFocusToken) { _, _ in
            withAnimation(.snappy(duration: 0.22)) {
                isSearchExpanded = true
            }
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            if canGoUp {
                GlassIconButton(systemName: "chevron.left", help: "Dossier parent") {
                    goUp()
                }
            } else if let root = store.rootURL {
                Image(nsImage: FileIconProvider.shared.icon(for: root, isDirectory: true))
                    .resizable()
                    .frame(width: 16, height: 16)
                    .padding(.leading, 2)
            }

            Text(currentDirectory?.lastPathComponent ?? "cactMD")
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(currentDirectory?.path ?? "Aucun dossier ouvert")

            Spacer(minLength: 2)

            // "New" leads the action group: it is the panel's primary verb,
            // the browse-mode switch only changes how the same list is drawn.
            if store.rootURL != nil {
                GlassMenuButton(help: "Nouveau") {
                    Button("Nouvelle note") {
                        clearFilterIfNeeded()
                        store.createNewNote(near: currentDirectory)
                    }
                    Button("Nouveau depuis un modèle…") {
                        clearFilterIfNeeded()
                        store.presentTemplatePicker()
                    }
                    Button("Nouveau dossier") {
                        clearFilterIfNeeded()
                        store.createNewFolder(near: currentDirectory)
                    }
                    Divider()
                    Button("Ouvrir un dossier…") {
                        store.chooseFolder()
                    }
                }
            } else {
                GlassIconButton(systemName: "folder.badge.plus", help: "Ouvrir un dossier…") {
                    store.chooseFolder()
                }
            }

            if store.rootURL != nil {
                GlassIconButton(
                    systemName: mode == .icons ? "list.bullet.indent" : "square.grid.2x2",
                    help: mode == .icons ? "Vue arborescence" : "Vue icônes"
                ) {
                    toggleMode()
                }
            }

            GlassIconButton(
                systemName: "magnifyingglass",
                help: "Filtrer l'explorateur (⌘F)",
                isActive: isSearchExpanded
            ) {
                toggleSearch()
            }

            GlassIconButton(systemName: "sidebar.left", help: "Afficher ou masquer le Finder") {
                withAnimation(.snappy(duration: 0.22)) {
                    store.toggleSidebar()
                }
            }
        }
        // The bubble's own top edge sits at 50 pt (aligned with the white
        // sheet); 14 pt of inner air keeps the "Documents" row clear of it.
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    /// Compact translucent switch between browsing the folder and the recent
    /// Markdown notes. Sits inside the existing bubble, so its top edge and
    /// overall height stay exactly where they were.
    private var tabSelector: some View {
        HStack(spacing: 2) {
            tabButton("Dossier", systemImage: "folder", tab: .folder)
            tabButton("Récents", systemImage: "clock", tab: .recents)
        }
        .padding(2)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(
            Capsule().strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.35), .white.opacity(0.08)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.75
            )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func tabButton(_ title: String, systemImage: String, tab: FinderSidebarTab) -> some View {
        let isSelected = sidebarTab == tab
        return Button {
            guard sidebarTab != tab else { return }
            withAnimation(.snappy(duration: 0.18)) {
                sidebarTab = tab
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.primary.opacity(0.10))
                        .overlay(
                            Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                        )
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tab == .folder ? "Parcourir le dossier" : "Notes récentes")
    }

    private var searchPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            TextField("Filtrer…", text: $store.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isSearchFocused)

            if !store.searchQuery.isEmpty {
                Button {
                    store.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Effacer le filtre")
            }

            // The filter above only narrows the explorer. This is the way out of
            // it: the same loupe, pointed at every note's content.
            Button {
                collapseSearch()
                store.presentSearch()
            } label: {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Rechercher dans toutes les notes (⌘⇧F)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(
            Capsule().strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.35), .white.opacity(0.08)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.75
            )
        )
        .onExitCommand {
            collapseSearch()
        }
    }

    private func tagChip(_ tag: String) -> some View {
        HStack(spacing: 6) {
            Text("#\(tag)")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.14), in: Capsule())

            if store.isTagIndexLoading {
                ProgressView()
                    .controlSize(.mini)
            }

            Spacer(minLength: 0)

            Button {
                store.applyTagFilter(nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Retirer le filtre")
        }
    }

    private var glassDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(height: 0.75)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if store.rootURL == nil {
            openFolderState
        } else if sidebarTab == .recents {
            recentsContent
        } else if mode == .icons {
            FinderIconGridView(
                store: store,
                nodes: gridNodes,
                emptyMessage: emptyMessage,
                currentDirectory: currentDirectory,
                selectedURL: $iconSelection,
                onOpen: open
            )
        } else if store.displayedNodes.isEmpty {
            emptyState
        } else {
            FinderOutlineView(
                nodes: store.displayedNodes,
                treeRevision: store.treeRevision,
                isFiltering: isFiltering,
                selectedURL: $store.selectedOutlineURL,
                pendingRenameURL: $store.pendingRenameURL,
                nodeLookup: { store.node(for: $0) },
                onSelect: { store.selectOutlineItem($0) },
                onRevealInFinder: { store.revealInFinder(url: $0) },
                onNewNote: { store.createNewNote(near: $0) },
                onNewFolder: { store.createNewFolder(near: $0) },
                onDuplicate: { store.duplicateItem(at: $0) },
                onTrash: { store.trashItem(at: $0) },
                onRename: { store.renameItem(at: $0, to: $1) },
                onSetFinderTag: { store.setFinderTag($1, for: $0) },
                onExpand: { store.ensureChildrenLoaded(for: $0) }
            )
        }
    }

    private var openFolderState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Aucun dossier ouvert")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Ouvrir un dossier…") {
                store.chooseFolder()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Recents

    private var filteredRecentNotes: [RecentNote] {
        let query = store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.recentNotes }
        return store.recentNotes.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.folder.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private var recentsContent: some View {
        let items = filteredRecentNotes
        if items.isEmpty {
            VStack {
                Spacer()
                Text(recentsEmptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(items) { note in
                        RecentNoteRow(note: note, isSelected: iconSelection == note.url) {
                            openRecent(note)
                        }
                        .contextMenu {
                            Button("Ouvrir") {
                                openRecent(note)
                            }
                            Button("Révéler dans le Finder") {
                                store.revealInFinder(url: note.url)
                            }
                            Divider()
                            Button("Déplacer vers la corbeille") {
                                store.trashItem(at: note.url)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
        }
    }

    private var recentsEmptyMessage: String {
        let query = store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return "Aucun résultat pour « \(query) »"
        }
        return "Aucune note récente"
    }

    private var emptyState: some View {
        VStack {
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

    private var emptyMessage: String {
        if let tag = store.activeTagFilter {
            return store.isTagIndexLoading ? "Recherche des notes…#\(tag)" : "Aucune note avec #\(tag)"
        }
        if !store.searchQuery.isEmpty {
            return "Aucun résultat pour « \(store.searchQuery) »"
        }
        return "Aucun fichier"
    }

    // MARK: - Grid data

    private var gridNodes: [FileNode] {
        if isFiltering {
            return sorted(flattened(store.displayedNodes))
        }

        let source: [FileNode]
        if let current = currentDirectory {
            let currentPath = current.resolvingSymlinksInPath().path
            let rootPath = store.rootURL?.resolvingSymlinksInPath().path
            if currentPath != rootPath {
                let node = store.node(for: current)
                source = node?.children ?? []
            } else {
                source = store.rootNode?.children ?? []
            }
        } else {
            source = store.rootNode?.children ?? []
        }
        return sorted(source)
    }

    private func sorted(_ nodes: [FileNode]) -> [FileNode] {
        nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func flattened(_ nodes: [FileNode]) -> [FileNode] {
        var result: [FileNode] = []
        for node in nodes {
            result.append(node)
            if !node.children.isEmpty {
                result.append(contentsOf: flattened(node.children))
            }
        }
        return result
    }

    // MARK: - Navigation

    private func open(_ node: FileNode) {
        if node.isDirectory {
            navigate(node.url)
        } else {
            iconSelection = node.url
            store.selectOutlineItem(node.url)
        }
    }

    private func openRecent(_ note: RecentNote) {
        iconSelection = note.url
        store.selectOutlineItem(note.url)
    }

    private func navigate(_ url: URL) {
        guard let root = store.rootURL else { return }
        // A filter flattens the tree, so browsing a folder has to clear it first.
        clearFilterIfNeeded()
        let target = url == root ? nil : url
        withAnimation(.easeInOut(duration: 0.16)) {
            directory = target
            iconSelection = nil
        }

        store.selectedOutlineURL = url
    }

    private func goUp() {
        guard let current = currentDirectory, let root = store.rootURL else { return }
        let parent = current.deletingLastPathComponent()
        guard parent.path.hasPrefix(root.path) else { return }
        navigate(parent)
    }

    private func toggleMode() {
        withAnimation(.snappy(duration: 0.22)) {
            if mode == .icons {
                mode = .tree
                if let current = currentDirectory {
                    store.selectedOutlineURL = current
                }
            } else {
                mode = .icons
                if let selected = store.selectedOutlineURL {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDirectory),
                       isDirectory.boolValue {
                        directory = selected == store.rootURL ? nil : selected
                    } else {
                        let folder = selected.deletingLastPathComponent()
                        directory = folder == store.rootURL ? nil : folder
                    }
                    iconSelection = selected
                }
            }
            UserDefaults.standard.set(mode == .icons, forKey: "folderViewIsGrid")
        }
    }

    private func toggleSearch() {
        if isSearchExpanded {
            collapseSearch()
        } else {
            withAnimation(.snappy(duration: 0.22)) {
                isSearchExpanded = true
            }
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
    }

    private func collapseSearch() {
        withAnimation(.snappy(duration: 0.22)) {
            isSearchExpanded = false
        }
        isSearchFocused = false
        if !store.searchQuery.isEmpty {
            store.searchQuery = ""
        }
    }

    private func clearFilterIfNeeded() {
        if !store.searchQuery.isEmpty {
            store.searchQuery = ""
        }
        if store.activeTagFilter != nil {
            store.applyTagFilter(nil)
        }
    }
}

/// One row of the Récents list: Markdown icon, note name, parent folder and
/// relative date. Kept private so the bubble owns its own visual language.
private struct RecentNoteRow: View {
    let note: RecentNote
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.secondary.opacity(0.09))
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(note.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 4) {
                        Text(note.folder)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !note.relativeDayLabel.isEmpty {
                            Text("·")
                            Text(note.relativeDayLabel)
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.14)
                            : Color.primary.opacity(isHovering ? 0.05 : 0)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
