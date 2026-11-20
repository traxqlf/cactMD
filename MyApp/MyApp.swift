import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // « Capturer dans systemMD » (`NSServices` in Info.plist) is routed to
        // this object. Registering before the launch completes means the entry
        // is already live when the system starts the app for a capture.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NotificationCenter.default.post(name: .systemMDExternalOpen, object: url)
        }
    }

    // MARK: - Services

    /// Receives the text selected in Safari, Terminal, Preview or any other app
    /// (send type `NSStringPboardType`). The app comes forward and the store
    /// files the text in `Inbox/Capture-YYYY-MM-DD.md`.
    @objc func captureSelection(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let selected = pasteboard.string(forType: .string)
            ?? pasteboard.string(forType: NSPasteboard.PasteboardType("NSStringPboardType"))
            ?? ""
        let text = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            error.pointee = "Aucun texte sélectionné." as NSString
            return
        }

        NSApp.activate()
        NotificationCenter.default.post(name: .systemMDCaptureText, object: text)
    }
}

/// Makes the SwiftUI window genuinely translucent so the glass panels can blur
/// the desktop, and pins the generous Pages-like minimum size.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowChromeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-applied on updates in case AppKit resets the style mask.
        (nsView as? WindowChromeView)?.applyWindowConfiguration()
    }
}

private final class WindowChromeView: NSView {
    /// Height of the glass band shared by the traffic lights and `TabBarView`.
    private static let headerBandHeight: CGFloat = 52
    /// Native unified-titlebar metrics: a 12 pt light every 20 pt, 8 pt apart.
    private static let trafficLightOriginsX: [CGFloat] = [20, 40, 60]

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyWindowConfiguration()
        observeWindowResize()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func applyWindowConfiguration() {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // No hairline under the titlebar: the top of the window is pure glass.
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        // NOTE: no NSToolbar here on purpose. An empty unified toolbar's view
        // covers the whole 52 pt titlebar band and swallows every mouse event
        // (clicks, hover) destined to the SwiftUI header below it. Dragging the
        // empty glass is handled by isMovableByWindowBackground instead.
        window.minSize = NSSize(width: 960, height: 640)
        // Empty glass (top strip, margins around the page) drags the window;
        // buttons, tabs and text fields keep their own mouse handling.
        window.isMovableByWindowBackground = true
        centerTrafficLights()
        scheduleTrafficLightCentering()
    }

    /// AppKit lays the traffic lights out again when the window becomes key or
    /// is first displayed, which would undo the custom offsets. Re-apply once
    /// the layout pass is over.
    private func scheduleTrafficLightCentering() {
        DispatchQueue.main.async { [weak self] in
            self?.centerTrafficLights()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.centerTrafficLights()
        }
    }

    // MARK: - Traffic lights

    private func observeWindowResize() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResizeNotification,
            object: nil
        )
        guard let window else { return }
        // AppKit re-lays out the titlebar on every resize: re-centre afterwards.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
        for name in [NSWindow.didBecomeKeyNotification,
                     NSWindow.didBecomeMainNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResize(_:)),
                name: name,
                object: window
            )
        }
    }

    @objc private func windowDidResize(_ notification: Notification) {
        centerTrafficLights()
    }

    /// Centres `closeButton`, `miniaturizeButton` and `zoomButton` vertically in
    /// the 52 pt header band, on the same axis as `TabBarView`.
    ///
    /// The titlebar container is grown to the band height and the buttons are
    /// moved inside it. Nothing is added on top of the SwiftUI header, so it
    /// keeps receiving its clicks exactly as before: only the three standard
    /// buttons are repositioned.
    private func centerTrafficLights() {
        guard let window,
              let close = window.standardWindowButton(.closeButton),
              let miniaturize = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let container = close.superview else { return }

        let band = Self.headerBandHeight
        // The buttons live in a private titlebar container; the theme frame
        // itself must never be resized.
        let isTitlebarContainer = NSStringFromClass(type(of: container))
            .localizedCaseInsensitiveContains("titlebar")

        if isTitlebarContainer,
           abs(container.frame.height - band) > 0.5,
           container.frame.width > 0 {
            var frame = container.frame
            frame.origin.y = frame.maxY - band
            frame.size.height = band
            container.frame = frame
        }

        let buttons = [close, miniaturize, zoom]

        if !isTrafficLightLayoutInstalled {
            // Frame-based positioning is undone by AppKit's own titlebar layout
            // on every layout pass. Auto Layout constraints survive it and pin
            // the native offsets from the window's leading edge.
            for (index, button) in buttons.enumerated() where index < Self.trafficLightOriginsX.count {
                button.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    button.leadingAnchor.constraint(
                        equalTo: container.leadingAnchor,
                        constant: Self.trafficLightOriginsX[index]
                    ),
                    button.centerYAnchor.constraint(equalTo: container.centerYAnchor)
                ])
            }
            isTrafficLightLayoutInstalled = true
        }

    }

    /// One-time switch from AppKit's frame layout to pinned constraints.
    private var isTrafficLightLayoutInstalled = false
}

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = WorkspaceStore()
    @StateObject private var updater = UpdaterViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 820)
        .defaultPosition(.center)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Rechercher des mises à jour…") {
                    updater.checkForUpdates()
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("Nouvelle note") {
                    store.createNewNote(near: store.selectedOutlineURL)
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(store.rootURL == nil)

                Button("Nouveau depuis un modèle…") {
                    store.presentTemplatePicker()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(store.rootURL == nil)

                Button("Nouveau dossier") {
                    store.createNewFolder(near: store.selectedOutlineURL)
                }
                // ⌘⇧N now opens the template picker; the folder keeps a chord
                // of its own instead of silently losing one.
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(store.rootURL == nil)

                Divider()

                Button("Nouvel onglet") {
                    store.newTab()
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(store.rootURL == nil)

                Button("Fermer l'onglet") {
                    store.closeActiveTab()
                }
                .keyboardShortcut("w", modifiers: .command)

                Divider()

                Button("Ouvrir un dossier…") {
                    store.chooseFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            // File menu: a Markdown note is rendered and saved as a PDF (the
            // page comes from WebKit, not a printer); a PDF tab simply prints
            // itself through PDFKit.
            CommandGroup(replacing: .printItem) {
                Button(store.isPDFDocumentOpen ? "Imprimer…" : "Exporter en PDF…") {
                    if store.isPDFDocumentOpen {
                        store.printOpenPDF()
                    } else {
                        store.exportPDF()
                    }
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(store.openNoteURL == nil)
            }

            CommandGroup(after: .sidebar) {
                Button(store.isSidebarVisible ? "Masquer le Finder" : "Afficher le Finder") {
                    withAnimation(.snappy(duration: 0.22)) {
                        store.toggleSidebar()
                    }
                }
                .keyboardShortcut("\\", modifiers: .command)

                Divider()

                Button("Onglet suivant") {
                    store.selectNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(store.tabs.count < 2)

                Button("Onglet précédent") {
                    store.selectPreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(store.tabs.count < 2)

                Menu("Aller à l'onglet") {
                    ForEach(Array(store.tabs.prefix(9).enumerated()), id: \.element.id) { index, tab in
                        Button("\(index + 1). \(store.tabTitle(tab))") {
                            store.activateTab(at: index)
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    }
                }
                .disabled(store.tabs.isEmpty)
            }

            CommandMenu("Note") {
                Button("Recherche rapide…") {
                    store.presentQuickSwitcher()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(store.rootURL == nil)

                Button("Rechercher dans les notes…") {
                    store.presentSearch()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(store.rootURL == nil)

                Button("Filtrer l'explorateur") {
                    NotificationCenter.default.post(name: .systemMDFocusFinderSearch, object: nil)
                }
                .disabled(store.rootURL == nil)

                Divider()

                Button("Graphe des notes") {
                    store.toggleGraphPresentation()
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(store.rootURL == nil || store.isPDFDocumentOpen)

                Button(store.isFocusMode ? "Désactiver le mode Focus" : "Mode Focus (machine à écrire)") {
                    store.toggleFocusMode()
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(store.openNoteURL == nil || store.isPDFDocumentOpen)

                Button(store.isEditing ? "Mode lecture" : "Mode édition") {
                    store.toggleEditMode()
                }
                // ⌘E belongs to inline code in the editor; the mode toggle
                // keeps its own chord so it works while typing.
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(
                    store.openNoteURL == nil
                        || store.isPDFDocumentOpen
                        || store.isQuickSwitcherPresented
                        || store.isSearchPresented
                )

                Divider()

                Button("Copier en texte enrichi") {
                    store.copyNoteAsRichText()
                }
                .disabled(store.openNoteURL == nil || store.isPDFDocumentOpen)

                Button("Exporter en PDF…") {
                    store.exportPDF()
                }
                .disabled(store.openNoteURL == nil || store.isPDFDocumentOpen)

                Divider()

                Button("Précédent") {
                    store.goBack()
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!store.canGoBack)

                Button("Suivant") {
                    store.goForward()
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!store.canGoForward)
            }
        }
    }
}
