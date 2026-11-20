import AppKit
import Observation
import PDFKit
import SwiftUI

/// `PDFView` fits its pages against the bounds it already has, and SwiftUI only
/// hands out real dimensions one run-loop turn after `makeNSView`. With
/// `autoScales` applied at creation, the page kept the tiny "fit" computed for a
/// zero-width view and sat small in the middle of the window. Re-fitting on every
/// layout fixes it as soon as the real size exists — unless the reader zoomed on
/// purpose, in which case their scale is left alone.
final class AutoFittingPDFView: PDFView {
    /// Set by `⌘+`/`⌘-` and the toolbar, cleared by « Ajuster » and `⌘0`.
    var userDidManuallyZoom = false

    override func layout() {
        super.layout()
        applyFitIfNeeded()
    }

    /// SwiftUI sizes a representable with `setFrameSize` and may never flag it
    /// `needsLayout`, so `layout()` alone was not enough to re-fit the page.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyFitIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFitIfNeeded()
    }

    private func applyFitIfNeeded() {
        guard !userDidManuallyZoom, document != nil, bounds.width > 40 else { return }
        autoScales = true
        let fitScale = scaleFactorForSizeToFit
        guard fitScale.isFinite, fitScale > 0 else { return }
        if abs(scaleFactor - fitScale) > 0.01 {
            scaleFactor = fitScale
        }
    }
}

/// Owns the PDF view of the active tab. PDFKit keeps rendered page tiles and
/// font caches inside `PDFView` itself — clearing only `document` left ~65 Mo
/// behind on a two-page handout — so the whole view is destroyed when the PDF
/// tab leaves the hierarchy and rebuilt on the next one.
final class PDFViewHub {
    static let shared = PDFViewHub()

    private(set) var view: AutoFittingPDFView?
    private(set) var loadedURL: URL?

    /// Builds the view on first use; the following PDF tabs reuse it until
    /// `unload()` sends it away.
    func displayView() -> AutoFittingPDFView {
        if let view { return view }
        let view = AutoFittingPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        // `PDFView` has no `drawsBackground`: this is the property that tints the
        // gutter around the pages. A dynamic colour follows light/dark mode.
        view.backgroundColor = .textBackgroundColor
        // Page shadows cost a full layer per page for a 2 pt effect; the page
        // break lines already separate the pages.
        view.pageShadowsEnabled = false
        self.view = view
        return view
    }

    /// Installs an already-parsed document. Display settings are re-applied
    /// *after* the assignment (PDFKit resets some of them when a document
    /// lands) and `layoutDocumentView()` makes the fitted scale visible at once
    /// instead of on the next scroll. A document that is already this file is
    /// never re-assigned: that would rasterise every page again.
    func install(_ document: PDFDocument, for url: URL, in view: AutoFittingPDFView) {
        if let current = view.document?.documentURL?.standardizedFileURL,
           current == url.standardizedFileURL {
            loadedURL = url
            return
        }
        view.document = document
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.autoScales = true
        view.scaleFactor = view.scaleFactorForSizeToFit
        view.layoutDocumentView()
        loadedURL = url
    }

    /// Called when the PDF tab goes away: dropping the view is what actually
    /// returns the page tiles to the system.
    func unload() {
        guard let view else { return }
        self.view = nil
        loadedURL = nil
        autoreleasepool {
            view.clearSelection()
            view.highlightedSelections = nil
            view.document = nil
            view.removeFromSuperview()
        }
    }

    func printActiveDocument() {
        guard let view, view.document != nil, view.window != nil else { return }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        view.print(with: info, autoRotate: true)
    }
}

/// Page/zoom/search state of the PDF tab. It owns no document: the hub does,
/// and this object dies with the view so nothing survives a closed tab.
@Observable
final class PDFReaderController {
    @ObservationIgnored weak var view: PDFView?

    var pageIndex = 0
    var pageCount = 0
    var isSearchVisible = false
    var searchText = ""
    var matchCount = 0
    var activeMatch = 0
    var didFailToOpen = false
    /// True only when parsing outlives the 120 ms grace period, so a small
    /// handout never flashes a spinner.
    var isLoading = false

    @ObservationIgnored private var matches: [PDFSelection] = []

    func zoomIn() {
        (view as? AutoFittingPDFView)?.userDidManuallyZoom = true
        view?.zoomIn(nil)
    }

    func zoomOut() {
        (view as? AutoFittingPDFView)?.userDidManuallyZoom = true
        view?.zoomOut(nil)
    }

    /// Back to page-width, the way Aperçu's "Ajuster" behaves.
    func fit() {
        guard let view else { return }
        (view as? AutoFittingPDFView)?.userDidManuallyZoom = false
        view.autoScales = true
        view.scaleFactor = view.scaleFactorForSizeToFit
        view.layoutDocumentView()
    }

    func runSearch() {
        guard let view, let document = view.document else { return }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            resetSearch()
            return
        }

        matches = document.findString(query, withOptions: [.caseInsensitive])
        matchCount = matches.count
        activeMatch = matches.isEmpty ? 0 : 1
        view.highlightedSelections = matches
        if let first = matches.first {
            view.go(to: first)
        }
    }

    func nextMatch() {
        guard !matches.isEmpty else { return }
        activeMatch = activeMatch % matches.count + 1
        view?.go(to: matches[activeMatch - 1])
    }

    func previousMatch() {
        guard !matches.isEmpty else { return }
        activeMatch = activeMatch <= 1 ? matches.count : activeMatch - 1
        view?.go(to: matches[activeMatch - 1])
    }

    func resetSearch() {
        matches = []
        matchCount = 0
        activeMatch = 0
        view?.highlightedSelections = nil
    }

    func closeSearch() {
        isSearchVisible = false
        resetSearch()
    }

    func documentDidLoad(_ document: PDFDocument?) {
        isLoading = false
        didFailToOpen = document == nil
        pageCount = document?.pageCount ?? 0
        pageIndex = 0
        #if DEBUG
        FileHandle.standardError.write(Data(
            "[systemMD] pdfkit loaded \(pageCount) page(s)\n".utf8
        ))
        #endif
    }

    func pageDidChange(in view: PDFView) {
        guard let page = view.currentPage, let document = view.document else { return }
        pageIndex = document.index(for: page)
    }
}

/// Native PDF tab: PDFKit's `PDFView` plus a discreet page/zoom/search bar.
struct PDFReaderView: View {
    let url: URL

    @State private var controller = PDFReaderController()
    @State private var keyMonitor: Any?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                ZStack {
                    PDFKitView(url: url, controller: controller)

                    if controller.isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    }

                    if controller.didFailToOpen {
                        VStack(spacing: 8) {
                            Image(systemName: "doc.questionmark")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(.tertiary)
                            Text("Impossible d'ouvrir ce PDF")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                controlBar
            }

            if controller.isSearchVisible {
                searchBar
                    .padding(.top, 12)
                    .padding(.trailing, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { installKeyboardShortcuts() }
        .onDisappear { removeKeyboardShortcuts() }
        .onChange(of: controller.isSearchVisible) { _, isVisible in
            if isVisible {
                isSearchFocused = true
            }
        }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: 10) {
            Text("Page \(controller.pageCount == 0 ? 0 : controller.pageIndex + 1) / \(controller.pageCount)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer(minLength: 0)

            GlassIconButton(systemName: "minus.magnifyingglass", help: "Zoom arrière (⌘-)") {
                controller.zoomOut()
            }

            Button {
                controller.fit()
            } label: {
                Text("Ajuster")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help("Ajuster à la largeur (⌘0)")

            GlassIconButton(systemName: "plus.magnifyingglass", help: "Zoom avant (⌘+)") {
                controller.zoomIn()
            }

            GlassIconButton(
                systemName: "magnifyingglass",
                help: "Rechercher dans le PDF (⌘F)",
                isActive: controller.isSearchVisible
            ) {
                controller.isSearchVisible.toggle()
                if controller.isSearchVisible {
                    isSearchFocused = true
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.92))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Rechercher dans le PDF", text: $controller.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 190)
                .focused($isSearchFocused)
                .onSubmit { controller.runSearch() }
                .onChange(of: controller.searchText) { _, text in
                    if text.isEmpty {
                        controller.resetSearch()
                    }
                }

            Text(controller.matchCount == 0 ? "0" : "\(controller.activeMatch)/\(controller.matchCount)")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            Button {
                controller.previousMatch()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(controller.matchCount == 0)
            .help("Résultat précédent")

            Button {
                controller.nextMatch()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(controller.matchCount == 0)
            .help("Résultat suivant")

            Button {
                controller.closeSearch()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Fermer la recherche (Échap)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .floatingGlassPanel(cornerRadius: 12)
    }

    // MARK: - Keyboard

    /// ⌘F, ⌘+, ⌘- and ⌘0 are consumed here while a PDF tab is showing; the
    /// window-level monitor leaves them alone for exactly that reason.
    private func installKeyboardShortcuts() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if event.keyCode == 53, controller.isSearchVisible {
                controller.closeSearch()
                return nil
            }

            guard flags == .command,
                  let key = event.charactersIgnoringModifiers?.lowercased() else {
                return event
            }

            switch key {
            case "f":
                controller.isSearchVisible = true
                isSearchFocused = true
                return nil
            case "+", "=":
                controller.zoomIn()
                return nil
            case "-":
                controller.zoomOut()
                return nil
            case "0":
                controller.fit()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyboardShortcuts() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

// MARK: - PDFView bridge

private struct PDFKitView: NSViewRepresentable {
    let url: URL
    let controller: PDFReaderController

    func makeNSView(context: Context) -> PDFView {
        // `displayView` builds the hub's view on first use and reuses it after.
        let view = PDFViewHub.shared.displayView()
        controller.view = view
        context.coordinator.attach(view, controller: controller)
        context.coordinator.load(url, in: view, controller: controller)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard let view = view as? AutoFittingPDFView else { return }
        // Page turns, search highlights and the page counter all re-render this
        // bridge: when the view already shows this file, doing nothing is what
        // keeps it from rasterising the document again on every update.
        if let current = view.document?.documentURL?.standardizedFileURL,
           current == url.standardizedFileURL {
            context.coordinator.loadedURL = url
            return
        }
        guard context.coordinator.loadedURL != url else { return }
        controller.view = view
        context.coordinator.load(url, in: view, controller: controller)
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.detach()
        coordinator.controller?.view = nil
        PDFViewHub.shared.unload()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject {
        var loadedURL: URL?
        weak var controller: PDFReaderController?
        private weak var observedView: AutoFittingPDFView?
        private var loadTask: Task<Void, Never>?
        private var spinnerTask: Task<Void, Never>?

        /// Parses off the main thread: a heavy PDF used to freeze the window on
        /// the very click that opened its tab. The spinner only appears if the
        /// parse outlives 120 ms, so short files stay flash-free.
        func load(_ url: URL, in view: AutoFittingPDFView, controller: PDFReaderController) {
            self.controller = controller
            guard loadedURL != url else { return }
            loadTask?.cancel()
            spinnerTask?.cancel()
            loadedURL = url
            controller.isLoading = false
            controller.didFailToOpen = false

            spinnerTask = Task { @MainActor [weak controller] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                controller?.isLoading = true
            }

            loadTask = Task { @MainActor [weak self, weak view, weak controller] in
                let document = await Task.detached(priority: .userInitiated) {
                    PDFDocument(url: url)
                }.value
                self?.spinnerTask?.cancel()
                guard !Task.isCancelled, let self, let view, self.loadedURL == url else { return }
                controller?.isLoading = false
                if let document {
                    PDFViewHub.shared.install(document, for: url, in: view)
                }
                controller?.documentDidLoad(document)
            }
        }

        func attach(_ view: AutoFittingPDFView, controller: PDFReaderController) {
            self.controller = controller
            observedView = view
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged(_:)),
                name: .PDFViewPageChanged,
                object: view
            )
        }

        func detach() {
            loadTask?.cancel()
            spinnerTask?.cancel()
            loadTask = nil
            spinnerTask = nil
            controller?.isLoading = false
            if let observedView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: .PDFViewPageChanged,
                    object: observedView
                )
            }
            observedView = nil
            loadedURL = nil
            controller?.resetSearch()
        }

        @objc private func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView else { return }
            controller?.pageDidChange(in: view)
        }
    }
}
