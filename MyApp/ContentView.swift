import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkspaceStore

    // Single source of truth for the window-top layout: 0 + 52 + 0 = 52 pt, the
    // height of the unified titlebar/toolbar band the traffic lights sit in.
    private static let tabRowInset: CGFloat = 0
    private static let tabRowHeight: CGFloat = 52
    private static let sheetGap: CGFloat = 0

    /// Where the white sheet starts, and therefore where the bubble's top edge
    /// must sit so both panels share the same horizontal line.
    private var sheetTopOffset: CGFloat {
        Self.tabRowInset + Self.tabRowHeight + Self.sheetGap
    }

    @State private var keyMonitor: Any?
    @State private var mouseMonitor: Any?
    @State private var finderMode: FinderDisplayMode = Self.restoredFinderMode()

    private static func restoredFinderMode() -> FinderDisplayMode {
        // Mosaïque (grille) par défaut tant qu'aucun choix n'a été enregistré.
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "folderViewIsGrid") != nil else { return .icons }
        return defaults.bool(forKey: "folderViewIsGrid") ? .icons : .tree
    }
    @State private var finderDirectory: URL?
    @State private var finderSearchToken = 0
    @State private var isFullScreen = false

    /// The tab strip carries its own outer margin (see `TabBarView`), so these
    /// values are the *extra* room added in front of it.
    private static let tabBarBaseInset: CGFloat = 12
    /// Left edge once the traffic lights are not there to protect (Finder open,
    /// or Finder hidden in full screen): mirror the right-hand action row.
    private static let tabBarFlushInset: CGFloat = 14
    /// Windowed with the Finder hidden: the pills must start past the three
    /// traffic lights (the green light ends around 70 pt) with a comfortable
    /// gap, so the header reads as a deliberate row rather than a squeeze.
    private static let tabBarTrafficLightInset: CGFloat = 90

    /// The traffic lights are hidden by macOS in full screen, so the 90 pt
    /// reserve that protects them is only needed in a windowed window.
    private var tabBarLeadingInset: CGFloat {
        guard !store.isSidebarVisible else { return 0 }
        let target = isFullScreen ? Self.tabBarFlushInset : Self.tabBarTrafficLightInset
        return target - Self.tabBarBaseInset
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The window itself is non-opaque: this blur is the desktop showing through.
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                if store.isSidebarVisible {
                    LeftFinderBubbleView(
                        store: store,
                        mode: $finderMode,
                        directory: $finderDirectory,
                        searchFocusToken: finderSearchToken
                    )
                    .frame(width: store.sidebarWidth)
                    .padding(.leading, 12)
                    // Same top edge as the white sheet (52 pt), so the bubble and
                    // the page start on one continuous line under the lights.
                    .padding(.top, sheetTopOffset)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                    FinderResizeHandle(width: $store.sidebarWidth)
                }

                mainColumn
            }
            .animation(.snappy(duration: 0.22), value: store.isSidebarVisible)


            overlayLayer
        }
        .frame(minWidth: 960, minHeight: 640)
        // Anchor the layout to the real top edge of the window: without this the
        // titlebar's safe-area inset pushes the header and tab row down.
        .ignoresSafeArea()
        .background(FullScreenObserver(isFullScreen: $isFullScreen))
        // The observer only writes the flag, one RunLoop turn later; the cross
        // fade between the two header insets is driven from here.
        .animation(.snappy(duration: 0.22), value: isFullScreen)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "systemmd" else { return .systemAction }

            let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "name" })?
                .value

            switch url.host {
            case "wikilink":
                if let name {
                    store.requestWikilinkOpen(name)
                    return .handled
                }
            case "tag":
                if let name {
                    store.applyTagFilter(name)
                    return .handled
                }
            default:
                break
            }
            return .systemAction
        })
        .onOpenURL { url in
            store.openExternalFile(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .systemMDFocusFinderSearch)) { _ in
            if !store.isSidebarVisible {
                withAnimation(.easeInOut(duration: 0.18)) {
                    store.setSidebarVisible(true)
                }
            }
            finderSearchToken += 1
        }
        .alert(
            "Erreur",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .confirmationDialog(
            "Créer la note « \(store.pendingWikilinkName ?? "") » ?",
            isPresented: Binding(
                get: { store.pendingWikilinkName != nil },
                set: { if !$0 { store.cancelWikilinkCreation() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Créer la note") {
                store.confirmWikilinkCreation()
            }
            Button("Annuler", role: .cancel) {
                store.cancelWikilinkCreation()
            }
        } message: {
            Text("Cette note n'existe pas encore dans le dossier ouvert.")
        }
        .onAppear {
            store.bootstrap()
            // The window is about to be visible: warm every recent note so the
            // first click in "Récents" is a synchronous cache hit.
            store.warmRecentNotes()
            installEditShortcutMonitor()
            installDoubleClickMonitor()
        }
        .onDisappear {
            store.flushPendingEdits()
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
        }
    }

    // MARK: - Layout

    private var mainColumn: some View {
        VStack(spacing: 0) {
            if store.rootURL != nil {
                TabBarView(store: store)
                    // 52 pt band at the very top: controls centre on the traffic lights.
                    .frame(height: Self.tabRowHeight)
                    .padding(.top, Self.tabRowInset)
                    // Keep the pills clear of the traffic lights when the bubble is hidden.
                    .padding(.leading, tabBarLeadingInset)
            }

            // A page laid on the workspace rather than a full-bleed canvas.
            ZStack {
                pageSurface

                if store.isGraphPresented {
                    KnowledgeGraphView(store: store)
                } else if store.isPDFDocumentOpen, let pdfURL = store.openNoteURL {
                    // A PDF never reaches `MarkdownWebView` or the `NSTextView`
                    // editor: PDFKit renders and owns its page.
                    PDFReaderView(url: pdfURL)
                } else {
                    MarkdownReaderView(store: store)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.10), radius: 16, y: 5)
            .padding(.horizontal, 12)
            // No gap under the tab row: 0 + 52 + 0 = 52 pt from the window top,
            // exactly the bubble's top edge. Without a tab row the sheet keeps
            // that same inset so the two panels stay level.
            .padding(.top, store.rootURL == nil ? sheetTopOffset : Self.sheetGap)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(workspaceBackdrop)
    }

    /// Barely-there glass between the bubble and the page.
    private var workspaceBackdrop: some View {
        Color(nsColor: .windowBackgroundColor)
            .opacity(0.28)
            .ignoresSafeArea()
    }

    /// The reading sheet itself: opaque enough to sit above the blur, with a
    /// hairline edge that stays legible in light and dark mode.
    private var pageSurface: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor).opacity(0.94))
    }

    @ViewBuilder
    private var overlayLayer: some View {
        if store.isQuickSwitcherPresented {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture {
                    store.dismissQuickSwitcher()
                }

            VStack {
                QuickSwitcherView(store: store)
                    .padding(.top, 96)
                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        } else if store.isTemplatePickerPresented {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture {
                    store.dismissTemplatePicker()
                }

            VStack {
                TemplatePickerView(store: store)
                    .padding(.top, 96)
                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        } else if store.isSearchPresented {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture {
                    store.dismissSearch()
                }

            VStack {
                SearchPaletteView(store: store)
                    .padding(.top, 96)
                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }

    // MARK: - Monitors

    private func installEditShortcutMonitor() {
        guard keyMonitor == nil else { return }
        // ⌘E is inline code while typing, so the Lecture/Édition toggle lives on
        // ⌘⇧E and is intercepted here: the same chord must work both ways, from
        // the reader and from inside the editor.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let paletteOpen = store.isQuickSwitcherPresented
                || store.isSearchPresented
                || store.isTemplatePickerPresented
            let modalBlocked = NSApp.modalWindow != nil
                || NSApp.mainWindow?.attachedSheet != nil
                || NSApp.keyWindow?.attachedSheet != nil

            if flags == [.command, .shift],
               event.charactersIgnoringModifiers?.lowercased() == "e",
               !paletteOpen,
               !store.isGraphPresented,
               NSApp.modalWindow == nil,
               store.openNoteURL != nil {
                store.toggleEditMode()
                return nil
            }

            // Cmd+F focuses the bubble's search pill. While editing, the event is
            // left to NSTextView so its own find bar keeps working; while a PDF
            // is showing, it belongs to the PDF's own search field.
            if flags == .command,
               event.charactersIgnoringModifiers?.lowercased() == "f",
               !paletteOpen,
               !store.isEditing,
               !store.isPDFDocumentOpen,
               !store.isGraphPresented,
               !modalBlocked,
               store.isSidebarVisible,
               store.rootURL != nil {
                finderSearchToken += 1
                return nil
            }

            // Tab and graph shortcuts are also claimed by AppKit defaults
            // (Show Fonts, Find Next), so they are handled before menu dispatch.
            if flags == .command,
               !modalBlocked,
               let key = event.charactersIgnoringModifiers?.lowercased() {
                if key.count == 1, let digit = Int(key), (1...9).contains(digit) {
                    store.activateTab(at: digit - 1)
                    return nil
                }

                switch key {
                case "t":
                    store.newTab()
                    return nil
                case "w":
                    store.closeActiveTab()
                    return nil
                case "g":
                    // A PDF tab has no graph to show: let the key through.
                    guard !store.isPDFDocumentOpen else { return event }
                    store.toggleGraphPresentation()
                    return nil
                default:
                    break
                }
            }

            // Space opens Quick Look only while hovering an image, so page scrolling is untouched.
            if event.keyCode == 49,
               flags.isEmpty,
               !store.isEditing,
               !store.isGraphPresented,
               !paletteOpen,
               NSApp.modalWindow == nil,
               let imageURL = store.hoveredImageURL {
                ImageQuickLook.shared.present(imageURL)
                return nil
            }

            return event
        }
    }

    private func installDoubleClickMonitor() {
        guard mouseMonitor == nil else { return }
        // SwiftUI text selection lives in a private AppKit view that swallows SwiftUI tap gestures,
        // so the double-click that reaches SwiftUI never fires over body text.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard event.clickCount == 2,
                  !store.isEditing,
                  // Double-click selects a word inside a PDF, it must not
                  // switch the tab to the Markdown editor.
                  !store.isPDFDocumentOpen,
                  !store.isQuickSwitcherPresented,
                  !store.isSearchPresented,
                  NSApp.modalWindow == nil,
                  store.openNoteURL != nil,
                  let contentView = event.window?.contentView,
                  let hit = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil)),
                  isSelectableText(hit) else {
                return event
            }
            store.beginEditing()
            return nil
        }
    }

    private func isSelectableText(_ view: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            if current is NSTextView
                || NSStringFromClass(type(of: current)).hasSuffix("AppKitTextInteractionView") {
                return true
            }
            candidate = current.superview
        }
        return false
    }
}

/// Tracks the hosting window's real full-screen state. SwiftUI has no native
/// signal for it, and `styleMask` also covers a window restored in full screen.
///
/// Two details keep this safe at the edges of a system transition:
/// - it listens to `didExit` rather than `willExit`, which fires while AppKit is
///   still animating the window back;
/// - every write to the state happens one RunLoop turn later and without an
///   ambient `withAnimation`, so it can never re-enter the layout pass that is
///   running (that re-entry surfaced as `NSInternalInconsistencyException`:
///   "The window has been marked as needing another Update Constraints in
///   Window pass"). The animation is left to `.animation(_:value:)` on the body.
private struct FullScreenObserver: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> NSView {
        ObserverView(isFullScreen: $isFullScreen)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? ObserverView)?.stopObserving()
    }

    final class ObserverView: NSView {
        private let isFullScreen: Binding<Bool>
        private var tokens: [NSObjectProtocol] = []
        /// Cleared as soon as the view leaves the hierarchy so a block queued by
        /// the last notification cannot write into a torn-down SwiftUI state.
        private var isActive = false

        init(isFullScreen: Binding<Bool>) {
            self.isFullScreen = isFullScreen
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            isActive = true

            let center = NotificationCenter.default
            for name in [
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification
            ] {
                tokens.append(center.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self, weak window] note in
                    self?.scheduleUpdate(for: note, window: window)
                })
            }

            // A window restored in full screen never posts `didEnter`, so the
            // initial read is deferred exactly like the callbacks.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, self.isActive, let window else { return }
                self.apply(window.styleMask.contains(.fullScreen))
            }
        }

        func stopObserving() {
            isActive = false
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens.removeAll()
        }

        /// Only the window hosting this view may move the state: a secondary
        /// window or a popover going full screen must not shift the header.
        private func scheduleUpdate(for note: Notification, window: NSWindow?) {
            guard let targetWindow = window, note.object as? NSWindow === targetWindow else { return }
            DispatchQueue.main.async { [weak self, weak targetWindow] in
                guard let self, self.isActive, let targetWindow else { return }
                self.apply(targetWindow.styleMask.contains(.fullScreen))
            }
        }

        /// Idempotent by design: the flag is read back from `styleMask`, which is
        /// the source of truth once the transition has settled.
        private func apply(_ value: Bool) {
            guard isFullScreen.wrappedValue != value else { return }
            isFullScreen.wrappedValue = value
        }

        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// Vertical handle letting the left bubble be resized. Dragging right widens it.
private struct FinderResizeHandle: View {
    @Binding var width: CGFloat
    @State private var dragStartWidth: CGFloat?
    @State private var isHovering = false

    private let minWidth: CGFloat = 240
    private let maxWidth: CGFloat = 480

    private var isDragging: Bool { dragStartWidth != nil }

    var body: some View {
        ZStack {
            Color.clear

            // The pill only exists on hover: no permanent grey seam between the
            // bubble and the page.
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(isHovering || isDragging ? 0.22 : 0))
                .frame(width: 3, height: isDragging ? 44 : 30)
                .shadow(color: .black.opacity(isHovering ? 0.16 : 0), radius: 2, y: 1)
        }
        .frame(width: 8)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .animation(.snappy(duration: 0.2), value: isDragging)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? width
                    if dragStartWidth == nil {
                        dragStartWidth = start
                    }
                    let proposed = start + value.translation.width
                    width = min(max(proposed, minWidth), maxWidth)
                }
                .onEnded { _ in
                    dragStartWidth = nil
                }
        )
    }
}

