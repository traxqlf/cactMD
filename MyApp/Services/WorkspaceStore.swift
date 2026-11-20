import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

extension Notification.Name {
    static let systemMDFocusEditor = Notification.Name("systemmd.focusEditor")
    static let systemMDExternalOpen = Notification.Name("systemmd.externalOpen")
    static let systemMDFocusFinderSearch = Notification.Name("systemmd.focusFinderSearch")
    /// object: the text selected in another app, captured through the macOS service.
    static let systemMDCaptureText = Notification.Name("systemmd.captureText")
    /// object: the heading block id to reveal in the editor's live buffer.
    static let systemMDScrollEditorToHeading = Notification.Name("systemmd.scrollEditorToHeading")
}

@Observable
final class WorkspaceStore {
    var rootURL: URL?
    var rootNode: FileNode?
    var searchQuery: String = "" {
        didSet {
            if searchQuery != oldValue {
                rebuildDisplayedNodes()
            }
        }
    }
    var displayedNodes: [FileNode] = []
    var treeRevision: Int = 0
    var allNotes: [NoteReference] = [] {
        didSet { noteIndexTreeCache = nil }
    }

    var selectedOutlineURL: URL?
    var openNoteURL: URL?
    var loadedNote: LoadedNote?
    /// The active tab shows a PDF: no Markdown parse, no render cache entry,
    /// no editor and no graph — PDFKit owns the page from here.
    var isPDFDocumentOpen: Bool {
        guard let openNoteURL else { return false }
        return FileTreeIndexer.isPDFFile(openNoteURL)
    }
    /// True between the moment a note is requested and the moment its blocks
    /// are ready. Lets the reader show progress instead of an empty page while
    /// a large or remote file is being read.
    var isNoteLoading = false
    /// True when the note being read is not the one on screen. The reader must
    /// then show progress rather than the previous note under the new title:
    /// that stale page made switching notes look like a dead click.
    var isSwitchingNote: Bool {
        isNoteLoading && loadedNote?.url != openNoteURL
    }
    var pendingRenameURL: URL?

    var tabs: [WorkspaceTab] = []
    var activeTabID: UUID = UUID()
    // Kept outside the tabs array so scrolling does not invalidate the tab bar.
    var activeScrollBlockID: Int?

    var isGraphPresented: Bool = false
    var graphData: KnowledgeGraphData?
    var isGraphLoading: Bool = false

    var isEditing: Bool = false
    var editorText: String = "" {
        didSet {
            if isEditing && !isApplyingEditorText && editorText != oldValue {
                editorDirty = true
                scheduleEditorSave()
            }
        }
    }

    var backlinks: [NoteReference] = []
    var backStack: [URL] = []
    var forwardStack: [URL] = []
    var isQuickSwitcherPresented: Bool = false
    var isTemplatePickerPresented: Bool = false
    var templateOptions: [NoteTemplate] = []
    var pendingWikilinkName: String?
    var pendingScrollBlockID: Int?
    /// Heading the reader or the editor is currently showing, so the outline can
    /// highlight the section in view.
    var activeHeadingID: Int?
    /// Typewriter mode: the edited line stays centred and the other paragraphs
    /// are dimmed. Persisted, it is a reading habit rather than a per-note one.
    var isFocusMode: Bool = UserDefaults.standard.bool(forKey: "focusModeEnabled") {
        didSet {
            UserDefaults.standard.set(isFocusMode, forKey: "focusModeEnabled")
        }
    }

    var isSearchPresented: Bool = false
    var searchHits: [SearchHit] = []
    var isSearching: Bool = false
    var activeTagFilter: String?
    var isTagIndexLoading: Bool = false
    var hoveredImageURL: URL?
    /// Last 20 opened or saved Markdown notes, newest first.
    var recentNotes: [RecentNote] = []

    var isSidebarVisible: Bool = true
    // 324 pt leaves room for three icon-grid columns (86–100 pt each, 4 pt
    // apart) plus the grid's 16 pt inset and a legacy scrollbar.
    var sidebarWidth: CGFloat = 324
    var errorMessage: String?

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    private var nodesByURL: [URL: FileNode] = [:]
    private var watcher: FSEventsWatcher?
    private var scanTask: Task<Void, Never>?
    private var noteIndexTask: Task<[NoteReference], Never>?
    private var isNoteIndexRunning = false
    private var needsNoteIndexRefresh = false
    /// Watcher paths waiting for the next tree pass to consume them.
    private var pendingWatcherPaths: Set<String> = []
    private var noteIndexGeneration = 0
    private var loadNoteTask: Task<Void, Never>?
    /// The read + parse behind `loadNoteTask`. Held separately so a new click
    /// can cancel the work itself, not only its result.
    private var noteParseTask: Task<RenderedNote, Error>?
    private var secondaryMetadataTask: Task<Void, Never>?
    /// True while the editor buffer is filled from the cache or disk: that is
    /// not a user edit, so it must not dirty the note or schedule a save.
    private var isApplyingEditorText = false
    private var loadingNoteURL: URL?
    private var noteLoadGeneration = 0
    private var editorSaveTask: Task<Void, Never>?
    private var backlinkTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var tagIndexTask: Task<Void, Never>?
    private var graphTask: Task<Void, Never>?
    private var graphRefreshTask: Task<Void, Never>?
    private var tagIndex: [URL: Set<String>] = [:]
    /// Folders whose direct children are already known, so expanding or opening
    /// one never enumerates twice.
    /// Resolved paths of folders whose direct children are already known.
    private var loadedDirectories: Set<String> = []
    /// Tree rebuilt from the note index, used while a name/tag filter is active.
    @ObservationIgnored private var noteIndexTreeCache: FileNode?
    private var externalOpenObserver: NSObjectProtocol?
    private var captureObserver: NSObjectProtocol?
    /// Text captured while no vault was open yet: replayed as soon as one is.
    private var pendingCaptureText: String?
    private var lastExternalOpenURL: URL?
    private var lastExternalOpenDate = Date.distantPast
    private var editorDirty = false
    private var ignoreWatcherUntil = Date.distantPast
    private var isBootstrapped = false
    private var recentNotePaths: [String] = []
    private var recentNotesTask: Task<Void, Never>?
    /// Silent background fill of the render cache for the first recent notes.
    private var recentPrewarmTask: Task<Void, Never>?
    /// Prefix parse that lets a large, cold note paint its first blocks fast.
    private var previewNoteTask: Task<LoadedNote?, Never>?
    /// Drops the renders of notes nobody is looking at when the app steps back.
    private var resignActiveObserver: NSObjectProtocol?
    /// Same cleanup on a slow clock, for sessions that never lose focus.
    private var housekeepingTimer: Timer?
    /// Contextual ✨ request waiting for the assistant popover to pick it up.
    var pendingAISelection: AISelectionRequest?
    /// Bumped when a contextual action must open the assistant popover.
    var aiAssistantOpenRequests = 0
    /// Live editor selection, shown in the popover while it is open.
    var editorSelectionPreview = ""
    /// Replaces the current selection from the assistant (undo stays native).
    @ObservationIgnored var replaceEditorSelection: ((String) -> Void)?
    /// Inserts the assistant result right below the selection.
    @ObservationIgnored var insertBelowEditorSelection: ((String) -> Void)?

    init() {
        isSidebarVisible = !UserDefaults.standard.bool(forKey: Self.sidebarHiddenDefaultsKey)
        let initialTab = WorkspaceTab()
        tabs = [initialTab]
        activeTabID = initialTab.id

        recentNotePaths = UserDefaults.standard.stringArray(forKey: Self.recentNotesDefaultsKey) ?? []
        refreshRecentNotes()

        externalOpenObserver = NotificationCenter.default.addObserver(
            forName: .systemMDExternalOpen,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = notification.object as? URL, let self else { return }
            Task { @MainActor in
                self.openExternalFile(url)
            }
        }

        // « Capturer dans systemMD » (Services menu) arrives without the app
        // even knowing whether a vault is open yet: the store decides.
        captureObserver = NotificationCenter.default.addObserver(
            forName: .systemMDCaptureText,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let text = notification.object as? String, let self else { return }
            Task { @MainActor in
                self.captureText(text)
            }
        }

        // Stepping away from the app is the cheapest moment to give memory back:
        // the notes the user is not looking at will not be needed before they
        // come back, and everything they *are* looking at is kept.
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.purgeRenderCacheInBackground()
        }

        // Meetings happen without leaving the app: the same soft purge also runs
        // every five minutes, on the main run loop but off the critical path.
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            self?.purgeRenderCacheInBackground()
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        housekeepingTimer = timer
    }

    deinit {
        if let externalOpenObserver {
            NotificationCenter.default.removeObserver(externalOpenObserver)
        }
        if let captureObserver {
            NotificationCenter.default.removeObserver(captureObserver)
        }
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
        }
        housekeepingTimer?.invalidate()
    }

    // MARK: - Contextual assistant

    /// Called from the editor's right-click menu: the popover opens on the tab
    /// bar and runs the action on the text that was selected.
    func requestAISelection(_ action: NoteAISelectionAction, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingAISelection = AISelectionRequest(action: action, text: text)
        aiAssistantOpenRequests &+= 1
    }

    func consumePendingAISelection() -> AISelectionRequest? {
        defer { pendingAISelection = nil }
        return pendingAISelection
    }

    // MARK: - Idle memory

    /// Renders that must survive a purge: the active note and every tab. Coming
    /// back to the app then stays a dictionary hit instead of a parse.
    private func pinnedRenderKeys() -> Set<String> {
        var urls: [URL] = []
        if let openNoteURL { urls.append(openNoteURL) }
        if let loadedNoteURL = loadedNote?.url { urls.append(loadedNoteURL) }
        for tab in tabs {
            if let noteURL = tab.noteURL { urls.append(noteURL) }
        }
        return Set(urls.map { NoteRenderCache.key(for: $0) })
    }

    /// Keeps the main thread free: canonicalising the open tabs costs a couple of
    /// `realpath` calls, the sweep itself walks the cache lock only.
    private func purgeRenderCacheInBackground() {
        let pinned = pinnedRenderKeys()
        Task { [weak self] in
            let removed = await Task.detached(priority: .utility) {
                NoteRenderCache.shared.purge(keeping: pinned, olderThan: 300)
            }.value
            #if DEBUG
            self?.logIdlePurge(removed, pinned: pinned.count)
            #endif
        }
    }

    #if DEBUG
    private func logIdlePurge(_ removed: Int, pinned: Int) {
        Self.debugLog(
            "[systemMD] idle purge: dropped \(removed), pinned \(pinned), cache now \(NoteRenderCache.shared.debugSummary)"
        )
    }
    #endif

    func bootstrap() {
        guard !isBootstrapped else { return }
        isBootstrapped = true

        #if DEBUG
        // Debug hook: opens a folder without the picker so a terminal run can
        // measure the real opening cost of a large folder.
        if rootURL == nil,
           let override = ProcessInfo.processInfo.environment["SYSTEMMD_OPEN_ROOT"],
           !override.isEmpty,
           isDirectory(at: URL(fileURLWithPath: override, isDirectory: true)) {
            openRootFolder(URL(fileURLWithPath: override, isDirectory: true))
            // `SYSTEMMD_OPEN_FILE` then opens a PDF in the first tab, so the
            // PDF path can be measured without any UI automation.
            if let file = ProcessInfo.processInfo.environment["SYSTEMMD_OPEN_FILE"],
               !file.isEmpty {
                let fileURL = URL(fileURLWithPath: file)
                if FileTreeIndexer.isOpenableFile(fileURL) {
                    openNote(at: fileURL)
                }
            }
            return
        }
        #endif

        // A Finder open event may already have set a root before the view appears.
        if rootURL == nil, let restored = BookmarkStore.restore() {
            openRootFolder(restored)
        }
    }

    func chooseFolder() {
        guard let url = BookmarkStore.pickFolder() else { return }
        openRootFolder(url)
    }

    func toggleSidebar() {
        setSidebarVisible(!isSidebarVisible)
    }

    /// Mirrors the persisted `@AppStorage("isSidebarHidden")` value: the
    /// store owns the state, the defaults key keeps it across launches.
    func setSidebarVisible(_ visible: Bool) {
        isSidebarVisible = visible
        UserDefaults.standard.set(!visible, forKey: Self.sidebarHiddenDefaultsKey)
    }

    func openRootFolder(_ url: URL) {
        // Canonical form: FileManager enumeration returns symlink-resolved paths (e.g. /private/var
        // for a /var root), so every derived URL must match or identity lookups fail.
        let standardized = canonicalURL(url)
        guard commitPendingEditorSave() else { return }

        rootURL = standardized
        refreshRecentNotes()
        rootNode = nil
        nodesByURL.removeAll()
        displayedNodes = []
        allNotes = []
        backlinks = []
        backStack = []
        forwardStack = []
        selectedOutlineURL = nil
        openNoteURL = nil
        loadedNote = nil
        noteLoadGeneration &+= 1
        loadingNoteURL = nil
        isNoteLoading = false
        isEditing = false
        activeScrollBlockID = nil
        activeHeadingID = nil
        resetTabs()
        isGraphPresented = false
        graphRefreshTask?.cancel()
        graphTask?.cancel()
        graphData = nil
        isGraphLoading = false
        isQuickSwitcherPresented = false
        pendingWikilinkName = nil
        isSearchPresented = false
        searchTask?.cancel()
        searchHits = []
        isSearching = false
        activeTagFilter = nil
        tagIndex = [:]
        isTagIndexLoading = false
        tagIndexTask?.cancel()
        hoveredImageURL = nil
        errorMessage = nil
        loadedDirectories = [standardized.resolvingSymlinksInPath().path]

        let openStart = CFAbsoluteTimeGetCurrent()
        var levelOneCount = 0

        // Depth 1 first: a single listing paints the explorer, whatever the size
        // of the folder or its iCloud status. The full crawl comes later.
        if let shallow = FileTreeIndexer.shallowScan(rootURL: standardized) {
            let reconciled = FileNode.reconcile(from: shallow, existingByURL: [:])
            rootNode = reconciled
            var map: [URL: FileNode] = [:]
            reconciled.flattenedNodesByURL(into: &map)
            nodesByURL = map
            levelOneCount = shallow.children.count
            rebuildDisplayedNodes()
            rebuildAllNotes()
        }

        #if DEBUG
        let elapsed = (CFAbsoluteTimeGetCurrent() - openStart) * 1000
        Self.debugLog(String(
            format: "[systemMD] level-1 ready in %.1f ms (%d items, %@)",
            elapsed,
            levelOneCount,
            standardized.lastPathComponent
        ))
        #endif

        // Only now that the level-1 list is published do we start listening to
        // the disk and crawling it in the background.
        startWatcher(for: standardized)
        noteIndexTask?.cancel()
        noteIndexTask = nil
        isNoteIndexRunning = false
        needsNoteIndexRefresh = false
        noteIndexGeneration &+= 1
        scheduleBackgroundNoteIndex()

        // A service capture fired before the vault was restored waits here.
        if let pending = pendingCaptureText {
            pendingCaptureText = nil
            errorMessage = nil
            captureText(pending)
        }
    }

    // MARK: - Quick capture

    /// Appends a text selected in another app to `Inbox/Capture-YYYY-MM-DD.md`
    /// and shows that note. Returns the daily file, `nil` when nothing could be
    /// written (no vault yet, or an I/O error).
    @discardableResult
    func captureText(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Service fired while the app was cold: restore the last vault now
        // instead of waiting for the window's `onAppear`.
        if rootURL == nil { bootstrap() }
        guard let root = rootURL else {
            pendingCaptureText = trimmed
            errorMessage = "Ouvrez d'abord un dossier dans cactMD pour capturer ce texte."
            return nil
        }

        // The daily note is often the one being edited: its buffer must reach
        // the disk first, or the append would be overwritten by the autosave.
        flushPendingEdits()

        do {
            let url = try QuickCaptureService.append(trimmed, to: root)
            if openNoteURL == url {
                loadNote(at: url, force: true)
            } else {
                openNote(at: url)
            }
            return url
        } catch {
            errorMessage = "Capture impossible : \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Navigation

    func selectOutlineItem(_ url: URL?) {
        selectedOutlineURL = url
        guard let url, !url.hasDirectoryPath, FileTreeIndexer.isOpenableFile(url) else {
            return
        }
        // No stat here: this runs on every click, and probing a dataless iCloud
        // item can block the main thread long enough for the whole UI to look
        // frozen. A missing file surfaces through `loadNote`'s error instead.

        if openNoteURL != url {
            openNote(at: url)
        } else if loadedNote == nil {
            loadNote(at: url)
        }
    }

    /// Opens a Markdown note or a PDF in the active tab. Both are "notes" to the
    /// tab strip, but only Markdown goes through the parse pipeline.
    func openNote(at url: URL) {
        guard FileTreeIndexer.isOpenableFile(url) else { return }

        if openNoteURL != url {
            guard commitPendingEditorSave(reloadNote: false) else { return }
            // The click wins: drop every read/parse still in flight for the
            // file being left, so its result can never land on the new page.
            cancelNoteLoads()
            if let current = openNoteURL {
                backStack.append(current)
                forwardStack.removeAll()
            }
            activeScrollBlockID = nil
            activeHeadingID = nil
        }

        isGraphPresented = false
        selectedOutlineURL = url
        // The tab follows the click immediately, even when the note lives in
        // a subfolder that was never opened in the tree.
        if tabs.indices.contains(activeTabIndex) {
            tabs[activeTabIndex].noteURL = url
        }
        loadNote(at: url)
    }

    func goBack() {
        guard let target = backStack.last else { return }
        guard commitPendingEditorSave() else { return }
        backStack.removeLast()
        if let current = openNoteURL {
            forwardStack.append(current)
        }
        activeScrollBlockID = nil
        activeHeadingID = nil
        isGraphPresented = false
        selectedOutlineURL = target
        loadNote(at: target)
    }

    func goForward() {
        guard let target = forwardStack.last else { return }
        guard commitPendingEditorSave() else { return }
        forwardStack.removeLast()
        if let current = openNoteURL {
            backStack.append(current)
        }
        activeScrollBlockID = nil
        activeHeadingID = nil
        isGraphPresented = false
        selectedOutlineURL = target
        loadNote(at: target)
    }

    func revealInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Finder tags

    /// Finder's seven colours in `labelNumber` order, index 0 = no tag.
    static let finderTagLabels = ["Aucun", "Gris", "Vert", "Violet", "Bleu", "Jaune", "Rouge", "Orange"]

    /// The value Finder itself stores in `kMDItemUserTags` for a standard colour.
    ///
    /// The tag name is localised by the system, and writing an English name on a
    /// French machine makes cfurl reset `labelNumber` to 0 (verified): the dot
    /// then disappears. The table keeps the two fields in agreement; unknown
    /// languages fall back to the English names.
    private static let finderTagNames: [String: [String]] = [
        "fr": ["Gris", "Vert", "Violet", "Bleu", "Jaune", "Rouge", "Orange"],
        "en": ["Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"],
        "de": ["Grau", "Grün", "Violett", "Blau", "Gelb", "Rot", "Orange"],
        "es": ["Gris", "Verde", "Violeta", "Azul", "Amarillo", "Rojo", "Naranja"],
        "it": ["Grigio", "Verde", "Viola", "Blu", "Giallo", "Rosso", "Arancione"],
        "nl": ["Grijs", "Groen", "Paars", "Blauw", "Geel", "Rood", "Oranje"],
        "pt": ["Cinza", "Verde", "Roxo", "Azul", "Amarelo", "Vermelho", "Laranja"]
    ]

    private static func finderTagName(for label: Int) -> String? {
        guard label >= 1, label <= 7 else { return nil }
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let names = finderTagNames[language] ?? finderTagNames["en"] ?? []
        guard names.indices.contains(label - 1) else { return nil }
        return names[label - 1]
    }

    /// The colour dot currently written on disk, 0 when the item is untagged.
    func finderTag(for url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.labelNumberKey]))?.labelNumber ?? 0
    }

    /// Writes the standard Finder colour. `labelNumber` draws the dot, `tagNames`
    /// keeps the tag list in Finder's inspector in step with it.
    ///
    /// The Swift `tagNames` setter only exists from macOS 26, so the tag list goes
    /// through Core Foundation, which has supported this key since 10.9. The
    /// colour is written last: a tag name the system does not recognise resets
    /// `labelNumber`, and the dot is what the user asked for.
    func setFinderTag(_ label: Int, for url: URL) {
        let clamped = min(7, max(0, label))
        let names = Self.finderTagName(for: clamped).map { [$0] } ?? []
        var cfError: Unmanaged<CFError>?
        CFURLSetResourcePropertyForKey(
            url as CFURL,
            kCFURLTagNamesKey as CFString,
            names as CFArray,
            &cfError
        )

        var values = URLResourceValues()
        values.labelNumber = clamped == 0 ? nil : clamped

        var target = url
        do {
            try target.setResourceValues(values)
            // The 3D folder icon embeds the tag dot: a stale icon would keep
            // showing the old colour.
            FileIconProvider.shared.invalidate(urls: [url])
            treeRevision &+= 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - External open

    func openExternalFile(_ url: URL) {
        guard url.isFileURL else { return }
        let canonical = canonicalURL(url)
        guard FileTreeIndexer.isOpenableFile(canonical) else { return }

        // Finder and SwiftUI can both deliver the same open event.
        if let lastExternalOpenURL,
           lastExternalOpenURL == canonical,
           Date().timeIntervalSince(lastExternalOpenDate) < 1.0 {
            return
        }
        lastExternalOpenURL = canonical
        lastExternalOpenDate = Date()

        closeSearch()
        isQuickSwitcherPresented = false

        if let rootURL, canonical.path.hasPrefix(rootURL.path + "/") {
            openNote(at: canonical)
        } else {
            openRootFolder(canonical.deletingLastPathComponent())
            openNote(at: canonical)
        }
    }

    // MARK: - Tabs

    var activeTabIndex: Int {
        tabs.firstIndex { $0.id == activeTabID } ?? 0
    }

    func tabURL(_ tab: WorkspaceTab) -> URL? {
        tab.id == activeTabID ? openNoteURL : tab.noteURL
    }

    func isTabEditing(_ tab: WorkspaceTab) -> Bool {
        tab.id == activeTabID ? isEditing : tab.isEditing
    }

    func tabTitle(_ tab: WorkspaceTab) -> String {
        guard let url = tabURL(tab) else { return "Nouvel onglet" }
        return url.deletingPathExtension().lastPathComponent
    }

    func newTab() {
        guard rootURL != nil, prepareForTabChange() else { return }
        let tab = WorkspaceTab()
        tabs.append(tab)
        activeTabID = tab.id
        restoreActiveTab()
    }

    func activateTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activateTab(id: tabs[index].id)
    }

    func activateTab(id: UUID) {
        guard id != activeTabID, tabs.contains(where: { $0.id == id }) else { return }
        guard prepareForTabChange() else { return }
        activeTabID = id
        restoreActiveTab()
    }

    func selectNextTab() {
        guard tabs.count > 1 else { return }
        activateTab(at: (activeTabIndex + 1) % tabs.count)
    }

    func selectPreviousTab() {
        guard tabs.count > 1 else { return }
        activateTab(at: (activeTabIndex - 1 + tabs.count) % tabs.count)
    }

    func closeActiveTab() {
        guard prepareForTabChange() else { return }
        let index = activeTabIndex
        tabs.remove(at: index)

        if tabs.isEmpty {
            let tab = WorkspaceTab()
            tabs = [tab]
            activeTabID = tab.id
        } else {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
        restoreActiveTab()
    }

    func closeTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        if id == activeTabID {
            closeActiveTab()
            return
        }
        tabs.removeAll { $0.id == id }
    }

    /// Saves the live editor and stores the current tab before it is replaced.
    private func prepareForTabChange() -> Bool {
        let wasEditing = isEditing
        if isEditing {
            if editorDirty, !saveEditorNow() {
                return false
            }
            editorSaveTask?.cancel()
            isEditing = false
        }
        snapshotActiveTab(editing: wasEditing)
        return true
    }

    private func snapshotActiveTab(editing: Bool? = nil) {
        guard tabs.indices.contains(activeTabIndex) else { return }
        let index = activeTabIndex
        tabs[index].noteURL = openNoteURL
        tabs[index].isEditing = (editing ?? isEditing) && openNoteURL != nil
        tabs[index].editorText = (editing ?? isEditing) ? editorText : ""
        tabs[index].topBlockID = activeScrollBlockID
        tabs[index].backStack = backStack
        tabs[index].forwardStack = forwardStack
    }

    private func restoreActiveTab() {
        guard tabs.indices.contains(activeTabIndex) else { return }
        let tab = tabs[activeTabIndex]
        editorSaveTask?.cancel()

        isQuickSwitcherPresented = false
        closeSearch()
        openNoteURL = tab.noteURL
        selectedOutlineURL = tab.noteURL
        loadedNote = nil
        backlinks = []
        // An empty tab must show the empty state, not the progress of a load
        // that belonged to the previous tab.
        cancelNoteLoads()
        backStack = tab.backStack
        forwardStack = tab.forwardStack
        // Assign the buffer while not editing so restoring it does not mark the tab dirty.
        isEditing = false
        editorText = tab.editorText
        editorDirty = false
        isEditing = tab.isEditing && tab.noteURL != nil
        activeScrollBlockID = tab.topBlockID
        pendingScrollBlockID = nil
        isGraphPresented = false

        if let url = openNoteURL {
            loadNote(at: url)
        }
    }

    private func resetTabs() {
        let tab = WorkspaceTab()
        tabs = [tab]
        activeTabID = tab.id
    }

    // MARK: - Quick switcher

    func presentQuickSwitcher() {
        guard rootURL != nil else { return }
        closeSearch()
        isQuickSwitcherPresented = true
    }

    func dismissQuickSwitcher() {
        guard isQuickSwitcherPresented else { return }
        isQuickSwitcherPresented = false
        guard isEditing else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .systemMDFocusEditor, object: nil)
        }
    }

    func toggleFocusMode() {
        isFocusMode.toggle()
    }

    // MARK: - Templates

    func presentTemplatePicker() {
        guard rootURL != nil else { return }
        closeSearch()
        isQuickSwitcherPresented = false
        templateOptions = NoteTemplates.available(in: rootURL)
        isTemplatePickerPresented = true
    }

    func dismissTemplatePicker() {
        guard isTemplatePickerPresented else { return }
        isTemplatePickerPresented = false
        guard isEditing else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .systemMDFocusEditor, object: nil)
        }
    }

    /// Creates the note from a template, with `{{date}}`, `{{datetime}}` and
    /// `{{titre}}` resolved once against the chosen title.
    @discardableResult
    func createNote(from template: NoteTemplate, titled rawTitle: String) -> URL? {
        guard commitPendingEditorSave() else { return nil }
        guard let rootURL else { return nil }

        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            title = NoteTemplates.suggestedTitle(for: template)
        }
        if title.lowercased().hasSuffix(".md") {
            title = String(title.dropLast(3))
        }
        title = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let directory = openNoteURL?.deletingLastPathComponent() ?? rootURL
        let newURL = uniqueURL(in: directory, baseName: title, pathExtension: "md")
        let content = NoteTemplates.render(template.body, title: title)

        do {
            try content.write(to: newURL, atomically: true, encoding: .utf8)
            recordRecentNote(newURL)
            Task {
                await refreshTreeNow(reloadOpenNote: false)
                openNote(at: newURL)
            }
            return newURL
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Full-text search

    func presentSearch() {
        guard rootURL != nil else { return }
        searchTask?.cancel()
        searchTask = nil
        searchHits = []
        isSearching = false
        isQuickSwitcherPresented = false
        isSearchPresented = true
    }

    func dismissSearch() {
        guard isSearchPresented else { return }
        closeSearch()
        guard isEditing else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .systemMDFocusEditor, object: nil)
        }
    }

    private func closeSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearchPresented = false
        isSearching = false
        // A live `NSMetadataQuery` would keep polling the index: it is torn
        // down with the palette, so a closed search costs 0 % CPU.
        SpotlightSearchService.shared.stop()
    }

    func updateSearchQuery(_ rawQuery: String) {
        searchTask?.cancel()
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !allNotes.isEmpty else {
            searchHits = []
            isSearching = false
            SpotlightSearchService.shared.stop()
            return
        }

        let notes = allNotes
        let root = rootURL
        isSearching = true
        searchTask = Task { [weak self] in
            // Coalesce keystrokes before touching the vault.
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }

            // Spotlight first: the index answers in milliseconds and saves
            // reading every note. When it has nothing (no index, external
            // volume, brand-new vault) the exhaustive scan is the fallback.
            var hits: [SearchHit] = []
            if let root {
                let candidates = await SpotlightSearchService.shared.candidateURLs(for: query, in: root)
                if !candidates.isEmpty, !Task.isCancelled {
                    hits = await Task.detached(priority: .userInitiated) {
                        FullTextSearchService.hits(query: query, in: candidates, relativeTo: root)
                    }.value
                }
            }

            if hits.isEmpty, !Task.isCancelled {
                hits = await Task.detached(priority: .userInitiated) {
                    await FullTextSearchService.search(query: query, in: notes)
                }.value
            }

            guard let self, !Task.isCancelled, self.isSearchPresented else { return }
            self.searchHits = hits
            self.isSearching = false
        }
    }

    func openSearchHit(_ hit: SearchHit) {
        searchTask?.cancel()
        isSearchPresented = false
        isSearching = false
        SpotlightSearchService.shared.stop()
        openNote(at: hit.note.url)
    }

    // MARK: - Graph

    func toggleGraphPresentation() {
        if isGraphPresented {
            dismissGraph()
        } else {
            presentGraph()
        }
    }

    func presentGraph() {
        // The graph is built from Markdown links and tags only.
        guard rootURL != nil, !isPDFDocumentOpen else { return }
        // Keep the tab in edit mode: leaving the graph returns to the draft.
        if isEditing, !saveEditorNow() {
            return
        }
        isQuickSwitcherPresented = false
        closeSearch()
        isGraphPresented = true
        if graphData == nil {
            rebuildGraph()
        }
    }

    func dismissGraph() {
        isGraphPresented = false
    }

    func ensureGraphLoaded() {
        guard isGraphPresented, graphData == nil, !isGraphLoading else { return }
        rebuildGraph()
    }

    func openGraphNode(_ url: URL) {
        isGraphPresented = false
        openNote(at: url)
    }

    private func rebuildGraph() {
        graphTask?.cancel()
        let notes = allNotes
        guard !notes.isEmpty else {
            graphData = .empty
            isGraphLoading = false
            return
        }

        isGraphLoading = true
        graphTask = Task { [weak self] in
            let data = await Task.detached(priority: .utility) {
                KnowledgeGraphService.build(from: notes)
            }.value

            guard let self, !Task.isCancelled else { return }
            self.graphData = data
            self.isGraphLoading = false
        }
    }

    private func scheduleGraphRefresh() {
        guard isGraphPresented else { return }
        graphRefreshTask?.cancel()
        graphRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled, self.isGraphPresented else { return }
            self.rebuildGraph()
        }
    }

    // MARK: - Recent notes

    /// Promotes a note to the top of the history. Reserved for notes whose
    /// content actually reached the disk (autosave, ⌘S, creation): simply
    /// reading a note must leave the list exactly as it is, otherwise every
    /// consultation reshuffled the sidebar and the entry the user clicked
    /// jumped away from the pointer.
    func recordRecentNote(_ url: URL) {
        guard FileTreeIndexer.isMarkdownFile(url) else { return }

        // `realpath` is affordable here precisely because this no longer runs
        // on every open (where an iCloud metadata call stalled the main
        // thread): it only runs right after a write. The stored order stays
        // canonical so a symlinked path cannot be listed twice.
        let path = canonicalURL(url).path
        guard recentNotePaths.first != path else { return }

        recentNotePaths.removeAll { $0 == path }
        recentNotePaths.insert(path, at: 0)
        if recentNotePaths.count > Self.recentNotesLimit {
            recentNotePaths.removeLast(recentNotePaths.count - Self.recentNotesLimit)
        }
        persistRecentNotePaths()
        refreshRecentNotes()
    }

    /// Adds a note discovered while browsing, at the bottom of the history.
    /// Existing entries never move, and a read-only visit is not a save, so
    /// the new row earns the top spot only once the note is edited.
    private func appendRecentNoteIfMissing(_ url: URL) {
        guard FileTreeIndexer.isMarkdownFile(url) else { return }
        let path = url.path
        guard !recentNotePaths.contains(path) else { return }
        guard recentNotePaths.count < Self.recentNotesLimit else { return }

        recentNotePaths.append(path)
        persistRecentNotePaths()
        refreshRecentNotes()
    }

    /// Rebuilds the list from the stored paths without any disk access on the
    /// main thread: the panel must not wait on the filesystem (iCloud metadata
    /// can take seconds) every time a note is opened.
    private func refreshRecentNotes() {
        let known = Dictionary(
            recentNotes.map { ($0.url.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        recentNotes = recentNotePaths.map { path in
            if let cached = known[path] { return cached }
            let url = URL(fileURLWithPath: path)
            return RecentNote(
                url: url,
                name: url.deletingPathExtension().lastPathComponent,
                folder: recentFolderLabel(for: url),
                modificationDate: nil
            )
        }
        scheduleRecentNotesMetadataRefresh()
        scheduleRecentNotesPrewarm()
    }

    /// Warms the complete recent list (up to 20 notes) right after the first
    /// window frame. The render cache can hold all of them, so every click in
    /// "Récents" is a memory hit instead of a disk read and a `cmark` parse.
    private func scheduleRecentNotesPrewarm() {
        recentPrewarmTask?.cancel()
        let urls = recentNotes.prefix(Self.prewarmNotesLimit).map(\.url)
        guard !urls.isEmpty else { return }

        recentPrewarmTask = Task(priority: .utility) { [weak self] in
            // Let the window paint and the current note finish first.
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }

            // Four notes at a time keeps every core busy without starving the
            // main actor; the whole list is usually warm in well under a second.
            await withTaskGroup(of: Void.self) { group in
                var iterator = urls.makeIterator()
                var inFlight = 0

                func addNext() {
                    guard let url = iterator.next() else { return }
                    inFlight += 1
                    group.addTask {
                        // Parsing is still worth prewarming: a click swaps the
                        // parsed blocks into the SwiftUI page. The old TextKit
                        // document cache is gone, so no attributed string is
                        // built for notes the user has not opened.
                        //
                        // `contains` rather than `render`: a prewarm probe is
                        // not a use, and stamping the entry here kept every
                        // recent note permanently "fresh", which disabled the
                        // idle purge on vaults whose watcher keeps firing.
                        guard !NoteRenderCache.shared.contains(url) else { return }

                        let parse = Task.detached(priority: .utility) {
                            try await MarkdownRenderer.loadNote(at: url)
                        }
                        if let rendered = try? await parse.value {
                            NoteRenderCache.shared.store(
                                note: rendered.note,
                                text: rendered.text,
                                hasSecondaryMetadata: false
                            )
                        }
                    }
                }

                while inFlight < 4 { addNext() }
                while await group.next() != nil {
                    inFlight -= 1
                    guard !Task.isCancelled, self != nil else {
                        group.cancelAll()
                        return
                    }
                    addNext()
                }
            }
        }
    }

    /// Called once the window is on screen so preloading never competes with
    /// the first paint.
    func warmRecentNotes() {
        scheduleRecentNotesPrewarm()
    }

    /// Off-main pass that fills in modification dates and drops entries whose
    /// file disappeared. Coalesced: a burst of openings only costs one pass.
    private func scheduleRecentNotesMetadataRefresh() {
        recentNotesTask?.cancel()
        let paths = recentNotePaths
        guard !paths.isEmpty else { return }

        recentNotesTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }

            let snapshot = await Task.detached(priority: .utility) {
                paths.map { path -> (path: String, date: Date?, isDirectory: Bool) in
                    let url = URL(fileURLWithPath: path)
                    let values = try? url.resourceValues(
                        forKeys: [.isDirectoryKey, .contentModificationDateKey]
                    )
                    return (path, values?.contentModificationDate, values?.isDirectory == true)
                }
            }.value

            guard let self, !Task.isCancelled, self.recentNotePaths == paths else { return }

            var keptPaths: [String] = []
            var items: [RecentNote] = []
            keptPaths.reserveCapacity(snapshot.count)
            items.reserveCapacity(snapshot.count)

            for entry in snapshot where !entry.isDirectory {
                let url = URL(fileURLWithPath: entry.path)
                keptPaths.append(entry.path)
                items.append(
                    RecentNote(
                        url: url,
                        name: url.deletingPathExtension().lastPathComponent,
                        folder: self.recentFolderLabel(for: url),
                        modificationDate: entry.date
                    )
                )
            }

            if keptPaths != self.recentNotePaths {
                self.recentNotePaths = keptPaths
                self.persistRecentNotePaths()
            }
            self.recentNotes = items
        }
    }

    private func recentFolderLabel(for url: URL) -> String {
        let parent = url.deletingLastPathComponent()
        guard let rootURL else { return parent.lastPathComponent }
        if parent == rootURL { return rootURL.lastPathComponent }
        if parent.path.hasPrefix(rootURL.path + "/") {
            return String(parent.path.dropFirst(rootURL.path.count + 1))
        }
        return parent.lastPathComponent
    }

    private func persistRecentNotePaths() {
        UserDefaults.standard.set(recentNotePaths, forKey: Self.recentNotesDefaultsKey)
    }

    /// First run in a vault with no history: seed the list with the newest
    /// Markdown files, read off the main thread so opening stays instant.
    private func prefillRecentNotesIfNeeded(from notes: [NoteReference], root: URL) {
        guard recentNotePaths.isEmpty, !notes.isEmpty else { return }

        Task { [weak self] in
            let paths: [String] = await Task.detached(priority: .utility) {
                notes.compactMap { reference -> (String, Date)? in
                    guard let values = try? reference.url.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    ),
                    let date = values.contentModificationDate else {
                        return nil
                    }
                    return (reference.url.path, date)
                }
                .sorted { $0.1 > $1.1 }
                .prefix(20)
                .map(\.0)
            }.value

            guard let self,
                  self.rootURL == root,
                  self.recentNotePaths.isEmpty,
                  !paths.isEmpty else {
                return
            }
            self.recentNotePaths = paths
            self.persistRecentNotePaths()
            self.refreshRecentNotes()
        }
    }

    /// Renaming or moving a note keeps its history entry pointing at the file.
    private func remapRecentNotes(moving source: URL, to destination: URL) {
        var changed = false
        let remapped = recentNotePaths.map { path -> String in
            let target = remap(URL(fileURLWithPath: path), moving: source, to: destination).path
            if target != path { changed = true }
            return target
        }
        guard changed else { return }

        recentNotePaths = remapped
        persistRecentNotePaths()
        refreshRecentNotes()
    }

    private func removeRecentNotes(under url: URL) {
        let filtered = recentNotePaths.filter { !isSameOrDescendant(URL(fileURLWithPath: $0), of: url) }
        guard filtered.count != recentNotePaths.count else { return }

        recentNotePaths = filtered
        persistRecentNotePaths()
        refreshRecentNotes()
    }

    private static let recentNotesDefaultsKey = "systemMD.recentNotePaths"
    private static let sidebarHiddenDefaultsKey = "isSidebarHidden"
    private static let prewarmNotesLimit = 20


    /// Above this size a cold note gets a prefix render before the full parse.
    nonisolated private static let previewByteThreshold = 30_000
    /// Blocks in that first paint, and how much of the file it reads.
    nonisolated private static let previewBlockCount = 40
    nonisolated private static let previewByteBudget = 64 * 1024

    private static let recentNotesLimit = 20

    // MARK: - Tags

    func applyTagFilter(_ tag: String?) {
        guard let tag else {
            activeTagFilter = nil
            rebuildDisplayedNodes()
            return
        }

        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            activeTagFilter = nil
            rebuildDisplayedNodes()
            return
        }

        activeTagFilter = trimmed
        setSidebarVisible(true)
        searchQuery = ""
        rebuildDisplayedNodes()
        refreshTagIndex(for: trimmed)
    }

    private func refreshTagIndex(for tag: String) {
        tagIndexTask?.cancel()
        guard !allNotes.isEmpty else {
            isTagIndexLoading = false
            return
        }

        let notes = allNotes
        isTagIndexLoading = true
        tagIndexTask = Task { [weak self] in
            let index = await Task.detached(priority: .utility) {
                await TagIndexService.build(for: notes)
            }.value

            guard let self, !Task.isCancelled, self.activeTagFilter == tag else { return }
            // shortcut: the index is rebuilt on each tag click, not on every file change.
            self.tagIndex = index
            self.isTagIndexLoading = false
            self.rebuildDisplayedNodes()
        }
    }

    // MARK: - Wikilinks

    func requestWikilinkOpen(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let destination = trimmed
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? trimmed
        let target = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }

        if let reference = resolveNote(named: target) {
            openNote(at: reference.url)
        } else {
            pendingWikilinkName = target
        }
    }

    func confirmWikilinkCreation() {
        guard let name = pendingWikilinkName else { return }
        pendingWikilinkName = nil
        createNote(named: name)
    }

    func cancelWikilinkCreation() {
        pendingWikilinkName = nil
    }

    private func resolveNote(named rawName: String) -> NoteReference? {
        let target = normalizedNoteName(rawName)
        guard !target.isEmpty else { return nil }

        let matches = allNotes.filter {
            normalizedNoteName($0.name) == target
                || normalizedNoteName($0.relativePathWithoutExtension) == target
                || normalizedNoteName($0.relativePathWithoutExtension).hasSuffix("/" + target)
        }

        guard !matches.isEmpty else { return nil }
        if matches.count == 1 { return matches[0] }

        if let currentFolder = openNoteURL?.deletingLastPathComponent(),
           let sameFolder = matches.first(where: { $0.url.deletingLastPathComponent() == currentFolder }) {
            return sameFolder
        }
        return matches.first
    }

    private func normalizedNoteName(_ value: String) -> String {
        var result = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        if result.hasSuffix(".md") {
            result = String(result.dropLast(3))
        } else if result.hasSuffix(".markdown") {
            result = String(result.dropLast(9))
        }
        return result
    }

    // MARK: - Creation & file operations

    func createNewNote(near targetURL: URL? = nil) {
        guard commitPendingEditorSave() else { return }
        guard let directory = targetDirectory(for: targetURL) else { return }
        let newURL = uniqueURL(in: directory, baseName: "Sans titre", pathExtension: "md")
        do {
            try "# Sans titre\n\n".write(to: newURL, atomically: true, encoding: .utf8)
            recordRecentNote(newURL)
            Task {
                await refreshTreeNow(reloadOpenNote: false)
                openNote(at: newURL)
                pendingRenameURL = newURL
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func createNote(named rawName: String) -> URL? {
        guard commitPendingEditorSave() else { return nil }
        guard let rootURL else { return nil }

        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".md") {
            name = String(name.dropLast(3))
        }
        name = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let directory = openNoteURL?.deletingLastPathComponent() ?? rootURL
        let newURL = uniqueURL(in: directory, baseName: name, pathExtension: "md")

        do {
            try "# \(name)\n\n".write(to: newURL, atomically: true, encoding: .utf8)
            recordRecentNote(newURL)
            Task {
                await refreshTreeNow(reloadOpenNote: false)
                openNote(at: newURL)
            }
            return newURL
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func createNewFolder(near targetURL: URL? = nil) {
        guard commitPendingEditorSave() else { return }
        guard let directory = targetDirectory(for: targetURL) else { return }
        let newURL = uniqueURL(in: directory, baseName: "Nouveau dossier", pathExtension: nil)
        do {
            try FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: false)
            Task {
                await refreshTreeNow(reloadOpenNote: false)
                selectedOutlineURL = newURL
                pendingRenameURL = newURL
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func duplicateItem(at url: URL) {
        guard commitPendingEditorSave() else { return }
        let parent = url.deletingLastPathComponent()
        let isDir = isDirectory(at: url)
        let ext = isDir ? nil : (url.pathExtension.isEmpty ? nil : url.pathExtension)
        let stem = isDir ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let destination = uniqueURL(in: parent, baseName: "\(stem) copie", pathExtension: ext)

        do {
            try FileManager.default.copyItem(at: url, to: destination)
            Task {
                await refreshTreeNow(reloadOpenNote: false)
                selectedOutlineURL = destination
                if !isDir && FileTreeIndexer.isMarkdownFile(destination) {
                    openNote(at: destination)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func trashItem(at url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            if let openURL = openNoteURL, isSameOrDescendant(openURL, of: url) {
                editorSaveTask?.cancel()
                isEditing = false
                editorDirty = false
                openNoteURL = nil
                loadedNote = nil
                noteLoadGeneration &+= 1
                loadingNoteURL = nil
                isNoteLoading = false
                backlinks = []
                activeScrollBlockID = nil
                activeHeadingID = nil
            }
            if let selected = selectedOutlineURL, isSameOrDescendant(selected, of: url) {
                selectedOutlineURL = nil
            }
            tabs = tabs.map { tab in
                var updated = tab
                if let noteURL = updated.noteURL, isSameOrDescendant(noteURL, of: url) {
                    updated.noteURL = nil
                    updated.isEditing = false
                    updated.editorText = ""
                    updated.topBlockID = nil
                }
                return updated
            }
            backStack.removeAll { isSameOrDescendant($0, of: url) }
            forwardStack.removeAll { isSameOrDescendant($0, of: url) }
            removeRecentNotes(under: url)
            Task {
                await refreshTreeNow(reloadOpenNote: false)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameItem(at url: URL, to proposedName: String) {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":") else {
            return
        }

        let isDir = isDirectory(at: url)
        let finalName: String
        if !isDir,
           !url.pathExtension.isEmpty,
           (trimmed as NSString).pathExtension.isEmpty {
            finalName = "\(trimmed).\(url.pathExtension)"
        } else {
            finalName = trimmed
        }

        guard finalName != url.lastPathComponent else { return }

        let destination = url.deletingLastPathComponent().appendingPathComponent(finalName, isDirectory: isDir)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            errorMessage = "Un élément nommé « \(finalName) » existe déjà."
            return
        }

        do {
            try FileManager.default.moveItem(at: url, to: destination)
            // A rename changes the canonical key of every file below `url`.
            NoteRenderCache.shared.remove(url: url)
            NoteRenderCache.shared.remove(url: destination)

            if let openURL = openNoteURL {
                if openURL == url {
                    openNoteURL = destination
                    if let current = loadedNote {
                        loadedNote = LoadedNote(
                            url: destination,
                            modificationDate: current.modificationDate,
                            byteCount: current.byteCount,
                            blocks: current.blocks,
                            headings: current.headings,
                            frontmatter: current.frontmatter,
                            tags: current.tags,
                            wordCount: current.wordCount,
                            characterCount: current.characterCount
                        )
                    }
                } else if openURL.path.hasPrefix(url.path + "/") {
                    let relative = String(openURL.path.dropFirst(url.path.count + 1))
                    let remapped = destination.appendingPathComponent(relative)
                    openNoteURL = remapped
                    if let current = loadedNote {
                        loadedNote = LoadedNote(
                            url: remapped,
                            modificationDate: current.modificationDate,
                            byteCount: current.byteCount,
                            blocks: current.blocks,
                            headings: current.headings,
                            frontmatter: current.frontmatter,
                            tags: current.tags,
                            wordCount: current.wordCount,
                            characterCount: current.characterCount
                        )
                    }
                }
            }

            if selectedOutlineURL == url {
                selectedOutlineURL = destination
            }

            backStack = backStack.map { remap($0, moving: url, to: destination) }
            forwardStack = forwardStack.map { remap($0, moving: url, to: destination) }
            tabs = tabs.map { tab in
                var updated = tab
                if let noteURL = updated.noteURL {
                    updated.noteURL = remap(noteURL, moving: url, to: destination)
                }
                return updated
            }
            remapRecentNotes(moving: url, to: destination)

            Task {
                await refreshTreeNow(reloadOpenNote: true)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Moves an item into another folder (drag and drop in the icon grid).
    /// Mirrors `renameItem` so open notes, tabs and history follow the file.
    func moveItem(_ source: URL, into directory: URL) {
        guard commitPendingEditorSave() else { return }
        guard isDirectory(at: directory) else { return }
        guard !isSameOrDescendant(directory, of: source) else { return }
        guard source.deletingLastPathComponent() != directory else { return }

        let destination = directory.appendingPathComponent(
            source.lastPathComponent,
            isDirectory: isDirectory(at: source)
        )
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            errorMessage = "Un élément nommé « \(source.lastPathComponent) » existe déjà."
            return
        }

        do {
            try FileManager.default.moveItem(at: source, to: destination)
            NoteRenderCache.shared.remove(url: source)
            NoteRenderCache.shared.remove(url: destination)

            if let openURL = openNoteURL {
                let remapped = remap(openURL, moving: source, to: destination)
                if remapped != openURL {
                    openNoteURL = remapped
                    if let current = loadedNote {
                        loadedNote = LoadedNote(
                            url: remapped,
                            modificationDate: current.modificationDate,
                            byteCount: current.byteCount,
                            blocks: current.blocks,
                            headings: current.headings,
                            frontmatter: current.frontmatter,
                            tags: current.tags,
                            wordCount: current.wordCount,
                            characterCount: current.characterCount
                        )
                    }
                }
            }

            if selectedOutlineURL == source {
                selectedOutlineURL = destination
            }

            backStack = backStack.map { remap($0, moving: source, to: destination) }
            forwardStack = forwardStack.map { remap($0, moving: source, to: destination) }
            tabs = tabs.map { tab in
                var updated = tab
                if let noteURL = updated.noteURL {
                    updated.noteURL = remap(noteURL, moving: source, to: destination)
                }
                return updated
            }
            remapRecentNotes(moving: source, to: destination)

            ignoreWatcherUntil = Date().addingTimeInterval(0.4)
            // Debounced: a multi-item drop must not run several scans at once.
            scheduleTreeRefresh(reloadOpenNote: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Editing

    func beginEditing() {
        activeHeadingID = nil
        guard !isEditing,
              !isPDFDocumentOpen,
              let openNoteURL,
              loadedNote?.url == openNoteURL else {
            return
        }

        // The reader just rendered this note from cache: reuse its source
        // instead of reading the file again on the main thread.
        if let cached = NoteRenderCache.shared.render(for: openNoteURL) {
            editorText = cached.text
            editorDirty = false
            isEditing = true
            return
        }

        // Cache miss (note opened a moment ago, or changed on disk): read it in
        // the background and fill the buffer once it is there. `editorDirty`
        // guards the case where the user starts typing before the read ends.
        editorText = ""
        editorDirty = false
        isEditing = true
        let target = openNoteURL
        Task { @MainActor [weak self] in
            let source = await Task.detached(priority: .userInitiated) {
                try? String(contentsOf: target, encoding: .utf8)
            }.value
            guard let self, self.isEditing, self.openNoteURL == target, !self.editorDirty else {
                return
            }
            self.isApplyingEditorText = true
            self.editorText = source ?? ""
            self.isApplyingEditorText = false
            self.editorDirty = false
        }
    }

    func toggleEditMode() {
        // A PDF has no editable source: ⌘⇧E is a no-op there.
        guard !isPDFDocumentOpen else { return }
        if isEditing {
            endEditing()
        } else {
            beginEditing()
        }
    }

    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        activeHeadingID = nil
        if editorDirty, !saveEditorNow() {
            isEditing = true
            return
        }
        if let url = openNoteURL {
            // Force: the buffer was just written, the reader must re-read it even
            // if a load for that note is already running.
            loadNote(at: url, force: true)
        }
    }

    func flushPendingEdits() {
        guard isEditing else { return }
        _ = saveEditorNow()
    }

    /// Writes an AI-edited Markdown source over the open note, then refreshes
    /// the reader and the editor buffer from the same bytes. The pending
    /// autosave is cancelled first: it must never overwrite the new content
    /// with the previous draft a moment later.
    @discardableResult
    func replaceOpenNoteContent(with text: String) -> Bool {
        guard let url = openNoteURL else { return false }

        editorSaveTask?.cancel()
        editorSaveTask = nil
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        NoteRenderCache.shared.remove(url: url)
        editorDirty = false
        if isEditing {
            isApplyingEditorText = true
            editorText = text
            isApplyingEditorText = false
        }
        recordRecentNote(url)
        // Atomic writes replace the inode; ignore our own watcher echo.
        ignoreWatcherUntil = Date().addingTimeInterval(0.6)
        loadNote(at: url, force: true)
        return true
    }

    @discardableResult
    private func commitPendingEditorSave(reloadNote: Bool = true) -> Bool {
        guard isEditing else { return true }
        isEditing = false
        if editorDirty, !saveEditorNow() {
            isEditing = true
            return false
        }
        // When the edit is committed because another file is being opened,
        // re-reading this one would only start a parse that the click cancels
        // a moment later.
        if reloadNote, let url = openNoteURL {
            loadNote(at: url, force: true)
        }
        return true
    }

    private func scheduleEditorSave() {
        editorSaveTask?.cancel()
        editorSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            _ = self?.saveEditorNow()
        }
    }

    @discardableResult
    private func saveEditorNow() -> Bool {
        editorSaveTask?.cancel()
        editorSaveTask = nil
        guard editorDirty, let url = openNoteURL else { return true }

        do {
            try editorText.write(to: url, atomically: true, encoding: .utf8)
            // The bytes on disk no longer match the cached render.
            NoteRenderCache.shared.remove(url: url)
            editorDirty = false
            recordRecentNote(url)
            // Atomic saves replace the inode; ignore the watcher echo so the editor keeps its cursor.
            ignoreWatcherUntil = Date().addingTimeInterval(0.6)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func toggleTaskCheckbox(atLine line: Int) {
        guard let url = openNoteURL else { return }
        do {
            try MarkdownRenderer.toggleTaskCheckbox(at: url, line: line)
            NoteRenderCache.shared.remove(url: url)
            // A checkbox toggle is a real content change on disk.
            recordRecentNote(url)
            loadNote(at: url, force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Called by the reader page while scrolling, so the outline can mark the
    /// section in view.
    func setActiveHeading(_ blockID: Int?) {
        guard activeHeadingID != blockID else { return }
        activeHeadingID = blockID
    }

    func scrollToBlock(_ blockID: Int) {
        pendingScrollBlockID = blockID
        // The reader consumes `pendingScrollBlockID`; the editor works on its
        // own buffer and gets the heading through a notification instead.
        guard isEditing else { return }
        NotificationCenter.default.post(
            name: .systemMDScrollEditorToHeading,
            object: blockID
        )
    }

    func copyNoteAsRichText() {
        guard let url = openNoteURL, FileTreeIndexer.isMarkdownFile(url) else { return }
        if isEditing {
            guard saveEditorNow() else { return }
        }
        do {
            let payload = try NoteExporter.richTextPayload(for: url)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(payload.rtf, forType: .rtf)
            pasteboard.setData(payload.html, forType: .html)
            pasteboard.setString(payload.plain, forType: .string)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportPDF() {
        guard let url = openNoteURL, !FileTreeIndexer.isPDFFile(url) else { return }
        if isEditing {
            guard saveEditorNow() else { return }
        }

        // The reading web view is the preferred source: its PDF keeps the exact
        // Obsidian layout, highlighted code, tables and KaTeX. It is only usable
        // when it is actually showing this note (not in edit mode, not on
        // another note), otherwise the export renders offscreen.
        // In edit mode the reader's web view is out of the hierarchy and still
        // holds the pre-edit body, so it must not be the source.
        let live = isEditing ? nil : MarkdownWebViewController.live
        let controller = live?.renderedNoteURL == url ? live : nil
        let note = loadedNote
        let backlinks = self.backlinks
        let sidebarHidden = !isSidebarVisible

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".pdf"
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }

            Task { @MainActor in
                do {
                    let data: Data
                    if let controller {
                        data = try await controller.vectorPDF()
                    } else if let note {
                        data = try await MarkdownWebViewController.vectorPDF(
                            for: note,
                            backlinks: backlinks,
                            sidebarHidden: sidebarHidden
                        )
                    } else {
                        data = try NoteExporter.pdfData(for: url)
                    }
                    try data.write(to: destination, options: .atomic)
                } catch {
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// ⌘P on a PDF tab: nothing to export, the page itself goes to the printer.
    func printOpenPDF() {
        guard isPDFDocumentOpen else { return }
        PDFViewHub.shared.printActiveDocument()
    }

    func node(for url: URL) -> FileNode? {
        if let node = nodesByURL[url] { return node }
        let resolved = url.resolvingSymlinksInPath()
        if let node = nodesByURL[resolved] { return node }
        let standardized = url.standardizedFileURL
        if let node = nodesByURL[standardized] { return node }
        if let rootURL, url == rootURL || resolved == rootURL || standardized == rootURL {
            return rootNode
        }
        // Fallback: match by path (iCloud / symlink aliases may differ by object).
        let target = resolved.path
        if let hit = nodesByURL.values.first(where: { $0.url.resolvingSymlinksInPath().path == target }) {
            return hit
        }
        return nil
    }

    /// Fills a folder's direct children on demand: the outline calls this when a
    /// row is expanded, the icon grid when a folder is opened. Keeps browsing
    /// instant even while the background crawl is still running.
    func ensureChildrenLoaded(for url: URL) {
        guard rootURL != nil else { return }
        let resolvedURL = url.resolvingSymlinksInPath()
        let standardizedURL = url.standardizedFileURL

        // Never block an opening because a directory was seen before: the node
        // may have been recreated with empty children after a back navigation.
        // Always (re)read its direct children from disk on a canonical path.

        guard let node = node(for: url), node.isDirectory else {
            // Last resort: scan the folder directly and attach it to the root's
            // matching child so the grid can still open it.
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDir), isDir.boolValue {
                let indexed = FileTreeIndexer.shallowChildren(of: resolvedURL)
                if let parent = rootNode?.children.first(where: { $0.url.resolvingSymlinksInPath().path == resolvedURL.path }) {
                    parent.children = indexed.map { FileNode.reconcile(from: $0, existingByURL: nodesByURL) }
                    var map: [URL: FileNode] = [:]
                    parent.flattenedNodesByURL(into: &map)
                    nodesByURL.merge(map) { _, new in new }
                    loadedDirectories.insert(resolvedURL.path)
                    rebuildDisplayedNodes()
                }
            }
            return
        }

        loadedDirectories.insert(resolvedURL.path)
        loadedDirectories.insert(standardizedURL.path)
        loadedDirectories.insert(node.url.resolvingSymlinksInPath().path)

        let indexed = FileTreeIndexer.shallowChildren(of: node.url.resolvingSymlinksInPath())
        node.children = indexed.map { FileNode.reconcile(from: $0, existingByURL: nodesByURL) }
        var map: [URL: FileNode] = [:]
        node.flattenedNodesByURL(into: &map)
        nodesByURL.merge(map) { _, new in new }
        rebuildDisplayedNodes()
        // `allNotes` deliberately stays the background index: rebuilding it from
        // the loaded tree here would hide every note in an unexpanded folder.
    }

    // MARK: - Private

    private func startWatcher(for url: URL) {
        watcher?.stop()
        // 850 ms buckets a sync burst into one update instead of one per file.
        let newWatcher = FSEventsWatcher(debounceMilliseconds: 850) { [weak self] paths in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // An external write, rename or deletion invalidates the cached
                // render of the files it touched, whatever else happens next.
                NoteRenderCache.shared.invalidate(paths: paths)
                // Folder colors/badges may have changed (Finder label, custom icon).
                FileIconProvider.shared.invalidate(urls: paths.map { URL(fileURLWithPath: $0) })
                if self.isEditing {
                    // Our own autosave (and external edits) must never relaunch a tree scan while typing.
                    guard Date() >= self.ignoreWatcherUntil else { return }
                    self.scheduleTreeRefresh(reloadOpenNote: false, changedPaths: paths)
                    return
                }
                guard Date() >= self.ignoreWatcherUntil else { return }
                self.scheduleTreeRefresh(reloadOpenNote: true, changedPaths: paths)
            }
        }
        newWatcher.start(watching: url)
        watcher = newWatcher
    }

    private func scheduleTreeRefresh(reloadOpenNote: Bool, changedPaths: Set<String> = []) {
        // A cancelled pass may not have applied its own batch yet: keep every
        // path until one pass actually consumes them.
        pendingWatcherPaths.formUnion(changedPaths)
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }
            let paths = self.pendingWatcherPaths
            await self.refreshTreeNow(reloadOpenNote: reloadOpenNote, changedPaths: paths)
            // A cancelled pass never applied its batch: keep those paths so the
            // next one still patches them.
            if !Task.isCancelled {
                self.pendingWatcherPaths.subtract(paths)
            }
        }
    }

    /// Runs once the level-1 list is on screen: walks the vault off the main
    /// thread and publishes the note index behind search, tags, backlinks and
    /// the graph. The folder tree itself stays lazy — only expanded folders are
    /// ever materialised, so a 76 000-file folder costs no extra memory.
    private func scheduleBackgroundNoteIndex() {
        guard let rootURL else { return }

        // A watcher burst must never kill a pass that is already walking the
        // vault: remember it and refresh once the current pass completes.
        if isNoteIndexRunning {
            needsNoteIndexRefresh = true
            return
        }
        isNoteIndexRunning = true
        let generation = noteIndexGeneration

        #if DEBUG
        let start = CFAbsoluteTimeGetCurrent()
        #endif

        // The scan lives in its own detached task so that cancelling it actually
        // stops the walk: a detached child ignores its parent's cancellation.
        let scan = Task.detached(priority: .utility) { () -> [NoteReference] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return [] }
            return FileTreeIndexer.scanNotes(rootURL: rootURL)
        }
        noteIndexTask = scan

        Task { [weak self] in
            let notes = await scan.value
            guard !scan.isCancelled, !Task.isCancelled else { return }
            guard let self,
                  self.rootURL == rootURL,
                  self.noteIndexGeneration == generation else {
                return
            }

            self.isNoteIndexRunning = false
            self.allNotes = notes
            self.prefillRecentNotesIfNeeded(from: notes, root: rootURL)
            if self.activeTagFilter != nil {
                self.rebuildDisplayedNodes()
                if let tag = self.activeTagFilter {
                    self.refreshTagIndex(for: tag)
                }
            }
            if self.isGraphPresented {
                self.scheduleGraphRefresh()
            }

            #if DEBUG
            Self.debugLog(String(
                format: "[systemMD] note index %.0f ms (%d notes)",
                (CFAbsoluteTimeGetCurrent() - start) * 1000,
                notes.count
            ))
            #endif

            if self.needsNoteIndexRefresh {
                self.needsNoteIndexRefresh = false
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.scheduleBackgroundNoteIndex()
            }
        }
    }

    private func refreshTreeNow(reloadOpenNote: Bool, changedPaths: Set<String> = []) async {
        guard rootURL != nil else { return }

        // A watcher burst or a file operation only changes what is on screen:
        // re-read the folders that are actually loaded, not the whole vault.
        await reloadLoadedDirectories()

        if !isGraphPresented {
            // Drop stale metadata; the graph rebuilds from disk next time it opens.
            graphData = nil
        }

        if reloadOpenNote {
            reloadOpenNoteIfNeeded()
        }

        // A note edit is the common case by far. Re-walking 1 448 files to learn
        // that one of them changed cost ~4.7 s of disk and CPU on every keystroke
        // burst; only a vanished folder still needs the full walk.
        let needsFullIndex = changedPaths.isEmpty || Self.requiresFullNoteIndex(for: changedPaths)
        #if DEBUG
        Self.debugLog(String(
            format: "[systemMD] watcher batch %d path(s), full index: %@, sample: %@",
            changedPaths.count,
            needsFullIndex ? "yes" : "no",
            changedPaths.prefix(3).joined(separator: " | ")
        ))
        #endif

        if needsFullIndex {
            scheduleBackgroundNoteIndex()
        } else {
            applyNoteIndexChanges(changedPaths)
        }
    }

    /// A Markdown file is always patched in place, and so is a folder that still
    /// exists: writing a note also touches its parent, and the note's own path
    /// is part of the same batch. Only a path that disappeared can take unseen
    /// notes with it (deleted or renamed folder), so that is the one case that
    /// justifies re-walking the vault. Both paths are handled incrementally.
    private static func requiresFullNoteIndex(for paths: Set<String>) -> Bool {
        paths.contains { path in
            let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
            if pathExtension == "md" || pathExtension == "markdown" { return false }
            return !FileManager.default.fileExists(atPath: path)
        }
    }

    /// Patches `allNotes` for the files the watcher reported instead of rescanning
    /// the vault. A deleted note is dropped, an edited or newly created one is
    /// re-indexed on its own.
    private func applyNoteIndexChanges(_ paths: Set<String>) {
        guard let rootURL else { return }
        let rootPath = rootURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let generation = noteIndexGeneration
        // The watcher lets folders through (a folder event may delete notes):
        // only Markdown paths can ever enter the note index.
        let touched = paths
            .map { URL(fileURLWithPath: $0) }
            .filter(FileTreeIndexer.isMarkdownFile)
        guard !touched.isEmpty else { return }

        Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) { () -> (upserts: [NoteReference], removed: [URL]) in
                var upserts: [NoteReference] = []
                var removed: [URL] = []
                for url in touched {
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                          !isDirectory.boolValue else {
                        removed.append(url)
                        continue
                    }
                    let relativePath = url.path.hasPrefix(prefix)
                        ? String(url.path.dropFirst(prefix.count))
                        : url.lastPathComponent
                    upserts.append(
                        NoteReference(
                            url: url,
                            name: url.deletingPathExtension().lastPathComponent,
                            relativePath: relativePath,
                            folder: (relativePath as NSString).deletingLastPathComponent
                        )
                    )
                }
                return (upserts, removed)
            }.value

            guard let self, !Task.isCancelled,
                  self.rootURL?.path == rootPath,
                  self.noteIndexGeneration == generation else { return }

            let touchedPaths = Set(touched.map(\.path))
            var notes = self.allNotes.filter { !touchedPaths.contains($0.url.path) }
            notes.append(contentsOf: snapshot.upserts)
            notes.sort { lhs, rhs in
                if lhs.name != rhs.name {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
            }
            self.allNotes = notes

            if let tag = self.activeTagFilter {
                self.refreshTagIndex(for: tag)
            }
            if self.isGraphPresented {
                self.scheduleGraphRefresh()
            }

            #if DEBUG
            Self.debugLog(String(
                format: "[systemMD] note index patched %d file(s) in place (%d notes)",
                snapshot.upserts.count + snapshot.removed.count,
                notes.count
            ))
            #endif
        }
    }

    /// Depth-1 re-read of every folder the user has expanded or opened.
    private func reloadLoadedDirectories() async {
        let directories = loadedDirectories
        guard !directories.isEmpty else { return }

        let refreshed = await Task.detached(priority: .userInitiated) {
            var result: [(path: String, children: [IndexedNode])] = []
            result.reserveCapacity(directories.count)
            for path in directories {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                result.append((path, FileTreeIndexer.shallowChildren(of: url)))
            }
            return result
        }.value

        guard !Task.isCancelled, rootURL != nil else { return }

        for entry in refreshed {
            let url = URL(fileURLWithPath: entry.path, isDirectory: true)
            guard let node = node(for: url), node.isDirectory else { continue }
            node.children = entry.children.map { FileNode.reconcile(from: $0, existingByURL: nodesByURL) }
        }

        var map: [URL: FileNode] = [:]
        rootNode?.flattenedNodesByURL(into: &map)
        nodesByURL = map
        // Keep already-resolved folder icons: a global purge is what made the
        // grid flash grey -> blue on every navigation/reload.
        rebuildDisplayedNodes()
    }

    #if DEBUG
    /// Unbuffered diagnostics: `print` is block-buffered when stdout is a pipe.
    private static func debugLog(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
    #endif

    private func reloadOpenNoteIfNeeded() {
        guard !isEditing else { return }
        guard let url = openNoteURL else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
            loadNote(at: url)
        } else {
            openNoteURL = nil
            loadedNote = nil
            noteLoadGeneration &+= 1
            loadingNoteURL = nil
            isNoteLoading = false
            backlinks = []
        }
    }

    /// Loads a note for the reader. A second request for the note already in
    /// flight is ignored instead of cancelling it: the file watcher fires on
    /// every vault change, and on a slow (iCloud) volume restarting the read
    /// each time left the reader blank forever. Stale results are dropped by
    /// generation, so switching notes still shows the last opened one.
    ///
    /// Two paths: a note whose cached render still matches the file on disk is
    /// published synchronously (one stat, no read, no parse); anything else is
    /// read and parsed in a detached task that the next click cancels.
    /// Stops every read and parse still running for the note being left.
    /// Detached tasks check `isCancelled` at each block, and the generation
    /// fence makes sure a late result cannot overwrite the new page.
    private func cancelNoteLoads() {
        noteLoadGeneration &+= 1
        noteParseTask?.cancel()
        noteParseTask = nil
        previewNoteTask?.cancel()
        previewNoteTask = nil
        loadNoteTask?.cancel()
        loadNoteTask = nil
        // These publish into `loadedNote` for the file being left; cancelling
        // them keeps a switch from rendering the old note one last time.
        secondaryMetadataTask?.cancel()
        secondaryMetadataTask = nil
        backlinkTask?.cancel()
        backlinkTask = nil
        loadingNoteURL = nil
        isNoteLoading = false
    }

    private func loadNote(at url: URL, force: Bool = false) {
        guard !FileTreeIndexer.isPDFFile(url) else {
            publishPDFDocument(at: url)
            return
        }

        let isSameNote = openNoteURL == url

        // Same file, still loading: the click only re-selected it.
        if isSameNote, !force, loadingNoteURL == url, noteParseTask != nil {
            return
        }

        cancelNoteLoads()
        openNoteURL = url
        appendRecentNoteIfMissing(url)

        if !isSameNote {
            backlinks = []
        }

        let generation = noteLoadGeneration

        #if DEBUG
        let loadStart = CFAbsoluteTimeGetCurrent()
        #endif

        if !force, let cached = NoteRenderCache.shared.render(for: url) {
            // Everything needed is already in memory: paint this note before
            // returning, so the reader never flashes its loading state.
            publish(cached.note, text: cached.text, hasSecondaryMetadata: cached.hasSecondaryMetadata)

            #if DEBUG
            Self.debugLog(String(
                format: "[systemMD] note %@ served from cache in %.2f ms (%@)",
                url.lastPathComponent,
                (CFAbsoluteTimeGetCurrent() - loadStart) * 1000,
                NoteRenderCache.shared.debugSummary
            ))
            #endif
            return
        }

        // A new cold note: drop the previous file's page immediately. Keeping
        // it under the new title is exactly what made a recent-file click look
        // like the reader was stuck on the first note.
        if loadedNote?.url != url {
            loadedNote = nil
        }
        loadingNoteURL = url
        isNoteLoading = true

        // Cold, large note: paint the first blocks while the whole document is
        // still parsing. The prefix read and parse happen off the main actor,
        // and the result is dropped as soon as the full render lands (or the
        // user opens another note).
        let preview = Task.detached(priority: .userInitiated) { () -> LoadedNote? in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size > Self.previewByteThreshold else { return nil }
            return try? await MarkdownRenderer.loadPreview(
                at: url,
                maxBlocks: Self.previewBlockCount,
                maxBytes: Self.previewByteBudget
            )
        }
        previewNoteTask = preview
        Task { @MainActor [weak self] in
            guard let previewNote = await preview.value else { return }
            guard !Task.isCancelled else { return }
            guard let self, generation == self.noteLoadGeneration else { return }
            guard self.openNoteURL == url, !self.isEditing else { return }
            // The full parse (or another note) already won: never replace it
            // with a truncated document.
            guard self.loadedNote?.url != url else { return }

            self.loadingNoteURL = nil
            self.isNoteLoading = false
            self.loadedNote = previewNote
            self.errorMessage = nil
        }

        // The detached task owns the read + parse so cancelling it actually
        // stops the work (a plain child would finish anyway).
        let parse = Task.detached(priority: .userInitiated) {
            try await MarkdownRenderer.loadNote(at: url)
        }
        noteParseTask = parse
        loadNoteTask = Task { @MainActor [weak self] in
            let result = await parse.result

            guard !Task.isCancelled else { return }
            guard let self, generation == self.noteLoadGeneration else { return }
            self.loadingNoteURL = nil
            self.isNoteLoading = false
            guard self.openNoteURL == url else { return }

            switch result {
            case .success(let rendered):
                NoteRenderCache.shared.store(
                    note: rendered.note,
                    text: rendered.text,
                    hasSecondaryMetadata: false
                )
                self.publish(rendered.note, text: rendered.text, hasSecondaryMetadata: false)

                #if DEBUG
                Self.debugLog(String(
                    format: "[systemMD] note %@ parsed in %.1f ms (%d blocks, %.1f KB)",
                    url.lastPathComponent,
                    (CFAbsoluteTimeGetCurrent() - loadStart) * 1000,
                    rendered.note.blocks.count,
                    Double(rendered.note.byteCount) / 1024
                ))
                #endif
            case .failure(let error):
                if error is CancellationError { return }
                // Never keep the previous note's blocks under the new URL.
                if self.loadedNote?.url != url {
                    self.loadedNote = nil
                }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// A PDF tab skips every Markdown stage on purpose: no `NoteRenderCache`
    /// entry, no blocks, no backlinks, no recent-note promotion. The bytes are
    /// read once by PDFKit and released with the view.
    private func publishPDFDocument(at url: URL) {
        #if DEBUG
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        Self.debugLog(String(
            format: "[systemMD] pdf tab opened %@ (%.1f KB)",
            url.lastPathComponent,
            Double(bytes) / 1024
        ))
        #endif
        cancelNoteLoads()
        openNoteURL = url
        loadedNote = nil
        backlinks = []
        errorMessage = nil
        isNoteLoading = false
        isEditing = false
        editorDirty = false
        editorText = ""
        isGraphPresented = false
    }

    private func publish(_ note: LoadedNote, text: String, hasSecondaryMetadata: Bool) {
        loadedNote = note
        errorMessage = nil
        if pendingScrollBlockID == nil, let blockID = activeScrollBlockID {
            pendingScrollBlockID = blockID
        }
        scheduleBacklinkRefresh(for: note.url)
        if !hasSecondaryMetadata {
            scheduleSecondaryMetadata(for: note, text: text)
        }
    }

    private struct NoteSecondaryMetadata: Sendable {
        let headings: [NoteHeading]
        let tags: [String]
        let words: Int
        let characters: Int
    }

    /// Word count, outline and tags are measured after the note is on screen.
    /// They walk every block, which is exactly the kind of work that must not
    /// sit between a click and the first painted line.
    private func scheduleSecondaryMetadata(for note: LoadedNote, text: String) {
        secondaryMetadataTask?.cancel()
        let url = note.url
        let blocks = note.blocks

        secondaryMetadataTask = Task { [weak self] in
            let metadata = await Task.detached(priority: .utility) { () -> NoteSecondaryMetadata in
                let body = FrontmatterParser.split(text).body
                let statistics = NoteStatistics.measure(blocks: blocks)
                return NoteSecondaryMetadata(
                    headings: MarkdownRenderer.headings(in: blocks),
                    tags: MarkdownTagScanner.tags(in: body),
                    words: statistics.words,
                    characters: statistics.characters
                )
            }.value

            guard !Task.isCancelled, let self, self.loadedNote?.url == url else { return }
            guard let current = self.loadedNote else { return }

            let enriched = LoadedNote(
                url: current.url,
                modificationDate: current.modificationDate,
                byteCount: current.byteCount,
                blocks: current.blocks,
                headings: metadata.headings,
                frontmatter: current.frontmatter,
                tags: metadata.tags,
                wordCount: metadata.words,
                characterCount: metadata.characters
            )
            self.loadedNote = enriched
            // Keep the cache entry in step so a later hit shows the outline and
            // counters straight away.
            NoteRenderCache.shared.store(note: enriched, text: text, hasSecondaryMetadata: true)
        }
    }

    private func scheduleBacklinkRefresh(for url: URL) {
        backlinkTask?.cancel()
        let target = url.deletingPathExtension().lastPathComponent
        let candidates = allNotes.filter { $0.url != url }
        guard !candidates.isEmpty else { return }

        backlinkTask = Task {
            // Coalesce rapid note switching before touching the vault.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }

            let found = await Task.detached(priority: .utility) {
                BacklinkScanner.findBacklinks(to: target, in: candidates)
            }.value

            guard !Task.isCancelled, openNoteURL == url else { return }
            backlinks = found
        }
    }

    private func rebuildAllNotes() {
        guard let root = rootNode, let rootURL else {
            allNotes = []
            return
        }

        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        var references: [NoteReference] = []

        func collect(_ node: FileNode) {
            if node.isDirectory {
                for child in node.children {
                    collect(child)
                }
                return
            }

            guard FileTreeIndexer.isMarkdownFile(node.url) else { return }
            let relativePath = node.url.path.hasPrefix(prefix)
                ? String(node.url.path.dropFirst(prefix.count))
                : node.url.lastPathComponent
            let folder = (relativePath as NSString).deletingLastPathComponent

            references.append(
                NoteReference(
                    url: node.url,
                    name: node.url.deletingPathExtension().lastPathComponent,
                    relativePath: relativePath,
                    folder: folder
                )
            )
        }

        collect(root)

        allNotes = references.sorted { lhs, rhs in
            if lhs.name != rhs.name {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    private func rebuildDisplayedNodes() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFiltering = activeTagFilter != nil || !query.isEmpty

        // Filters must reach notes that live in folders nobody expanded yet, so
        // they run on a tree built from the background note index, not on the
        // lazy folder tree.
        var base = isFiltering ? (noteIndexTree()?.children ?? []) : (rootNode?.children ?? [])

        if let tag = activeTagFilter {
            let needle = tag.lowercased()
            let urls = Set(
                tagIndex.compactMap { url, tags in
                    tags.contains(where: { $0.lowercased() == needle }) ? url : nil
                }
            )
            base = filterNodes(base, matching: urls)
        }

        if !query.isEmpty {
            base = filterNodes(base, matching: query)
        }

        displayedNodes = base
        treeRevision += 1
    }

    /// Rebuilds a folder tree from the flat note index. Cached until the index
    /// changes: typing in the filter only walks matched nodes.
    private func noteIndexTree() -> FileNode? {
        if let noteIndexTreeCache { return noteIndexTreeCache }
        guard let rootURL else { return nil }

        let root = FileNode(
            url: rootURL,
            name: rootURL.lastPathComponent,
            isDirectory: true,
            modificationDate: nil
        )
        var folders: [String: FileNode] = [:]

        for reference in allNotes {
            let components = reference.relativePath.split(separator: "/").map(String.init)
            guard components.count >= 2 else {
                root.children.append(
                    FileNode(
                        url: reference.url,
                        name: reference.name,
                        isDirectory: false,
                        modificationDate: nil
                    )
                )
                continue
            }

            var path = ""
            var parent = root
            for component in components.dropLast() {
                path = path.isEmpty ? component : path + "/" + component
                if let existing = folders[path] {
                    parent = existing
                    continue
                }
                let folder = FileNode(
                    url: rootURL.appendingPathComponent(path, isDirectory: true),
                    name: component,
                    isDirectory: true,
                    modificationDate: nil
                )
                folders[path] = folder
                parent.children.append(folder)
                parent = folder
            }

            parent.children.append(
                FileNode(
                    url: reference.url,
                    name: reference.name,
                    isDirectory: false,
                    modificationDate: nil
                )
            )
        }

        sortTree(root)
        noteIndexTreeCache = root
        return root
    }

    private func sortTree(_ node: FileNode) {
        node.children.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        for child in node.children {
            sortTree(child)
        }
    }

    private func filterNodes(_ nodes: [FileNode], matching query: String) -> [FileNode] {
        var matches: [FileNode] = []
        for node in nodes {
            if node.isDirectory {
                let filteredChildren = filterNodes(node.children, matching: query)
                if !filteredChildren.isEmpty || node.name.localizedCaseInsensitiveContains(query) {
                    let copy = FileNode(
                        url: node.url,
                        name: node.name,
                        isDirectory: true,
                        modificationDate: node.modificationDate,
                        children: filteredChildren
                    )
                    matches.append(copy)
                }
            } else if node.name.localizedCaseInsensitiveContains(query) {
                matches.append(node)
            }
        }
        return matches
    }

    private func filterNodes(_ nodes: [FileNode], matching urls: Set<URL>) -> [FileNode] {
        var matches: [FileNode] = []
        for node in nodes {
            if node.isDirectory {
                let filteredChildren = filterNodes(node.children, matching: urls)
                if !filteredChildren.isEmpty {
                    let copy = FileNode(
                        url: node.url,
                        name: node.name,
                        isDirectory: true,
                        modificationDate: node.modificationDate,
                        children: filteredChildren
                    )
                    matches.append(copy)
                }
            } else if urls.contains(node.url) {
                matches.append(node)
            }
        }
        return matches
    }

    private func targetDirectory(for targetURL: URL?) -> URL? {
        guard let targetURL else { return rootURL }
        return isDirectory(at: targetURL) ? targetURL : targetURL.deletingLastPathComponent()
    }

    private func isDirectory(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func isSameOrDescendant(_ url: URL, of ancestor: URL) -> Bool {
        url == ancestor || url.path.hasPrefix(ancestor.path + "/")
    }

    private func remap(_ url: URL, moving source: URL, to destination: URL) -> URL {
        if url == source { return destination }
        guard url.path.hasPrefix(source.path + "/") else { return url }
        let relative = String(url.path.dropFirst(source.path.count + 1))
        return destination.appendingPathComponent(relative)
    }

    private func canonicalURL(_ url: URL) -> URL {
        guard let resolved = url.path.withCString({ realpath($0, nil) }) else {
            return url.standardizedFileURL
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: url.hasDirectoryPath)
    }

    private func uniqueURL(in directory: URL, baseName: String, pathExtension: String?) -> URL {
        let fm = FileManager.default
        var index = 1
        while true {
            let candidateStem = index == 1 ? baseName : "\(baseName) \(index)"
            let filename = if let ext = pathExtension, !ext.isEmpty {
                "\(candidateStem).\(ext)"
            } else {
                candidateStem
            }
            let candidate = directory.appendingPathComponent(filename, isDirectory: pathExtension == nil)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }
}
