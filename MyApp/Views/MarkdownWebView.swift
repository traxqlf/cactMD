import AppKit
import SwiftUI
import WebKit

@MainActor
final class MarkdownWebViewController: NSObject {
    let webView: WKWebView
    fileprivate var isReady = false
    fileprivate var pendingHTML: String?
    fileprivate var lastRenderedKey: String?
    /// Heading waiting to be revealed once the new body is in the DOM.
    private var pendingHeadingID: Int?

    weak var store: WorkspaceStore?

    /// The note the page currently shows, so the PDF export knows whether this
    /// controller is the right source for what the user is reading.
    private(set) var renderedNoteURL: URL?

    /// Most recently attached controller: the one whose web view is on screen.
    static weak var live: MarkdownWebViewController?

    private static let templateURL: URL? = resolveTemplateURL()

    override init() {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        let ucc = WKUserContentController()
        config.userContentController = ucc

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        if #available(macOS 14.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        self.webView = webView
        super.init()

        ucc.add(WeakScriptHandler(delegate: self), name: "openExternal")
        ucc.add(WeakScriptHandler(delegate: self), name: "link")
        ucc.add(WeakScriptHandler(delegate: self), name: "checkbox")
        ucc.add(WeakScriptHandler(delegate: self), name: "copy")
        ucc.add(WeakScriptHandler(delegate: self), name: "heading")

        webView.navigationDelegate = self
        loadTemplate()
    }

    private static func resolveTemplateURL() -> URL? {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: "index", withExtension: "html", subdirectory: "WebRenderer") { return url }
        if let base = bundle.resourceURL {
            let candidates = [
                base.appendingPathComponent("WebRenderer/index.html"),
                base.appendingPathComponent("index.html"),
            ]
            for c in candidates where FileManager.default.fileExists(atPath: c.path) {
                let dir = c.deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent("prism.min.js").path) || c.lastPathComponent == "index.html" {
                    // prefer one co-located with prism
                    if FileManager.default.fileExists(atPath: dir.appendingPathComponent("prism.min.js").path) { return c }
                }
            }
            for c in candidates where FileManager.default.fileExists(atPath: c.path) { return c }
            if let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) {
                for case let url as URL in e where url.lastPathComponent == "index.html" {
                    if FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("prism.min.js").path) { return url }
                }
            }
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("MyApp/Resources/WebRenderer/index.html")
        if FileManager.default.fileExists(atPath: cwd.path) { return cwd }
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/WebRenderer/index.html")
        if FileManager.default.fileExists(atPath: src.path) { return src }
        return nil
    }

    private func loadTemplate() {
        if let url = Self.templateURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.loadHTMLString(MarkdownHTMLRenderer.fallbackSkeletonHTML(), baseURL: nil)
        }
    }

    func render(note: LoadedNote, backlinks: [NoteReference]) {
        let key = "\(note.url.path)|\(note.modificationDate?.timeIntervalSinceReferenceDate ?? 0)|\(note.blocks.count)|\(backlinks.count)|\(note.wordCount)|\(note.frontmatter.count)"
        // Re-rendering the note already on screen (ticking a checkbox) must not
        // move the page: only a note switch starts again at the top.
        let isSameNote = renderedNoteURL == note.url
        renderedNoteURL = note.url
        guard key != lastRenderedKey else { return }
        lastRenderedKey = key
        let body = MarkdownHTMLRenderer.bodyHTML(note: note, backlinks: backlinks)
        setBodyHTML(body, keepScroll: isSameNote)
    }

    private func setBodyHTML(_ html: String, keepScroll: Bool = false) {
        guard isReady else { pendingHTML = html; return }
        let literal = MarkdownHTMLRenderer.jsStringLiteral(html)
        let js = "if(typeof setContent==='function'){setContent(\(literal), \(keepScroll));}"
        webView.evaluateJavaScript(js, completionHandler: { [weak self] _, _ in
            self?.applyPendingHeading()
        })
    }

    // MARK: - Outline

    /// Reveals a heading once the body it belongs to is in the DOM.
    func scrollToHeading(_ blockID: Int) {
        pendingHeadingID = blockID
        applyPendingHeading()
    }

    private func applyPendingHeading() {
        guard isReady, let blockID = pendingHeadingID else { return }
        pendingHeadingID = nil
        webView.evaluateJavaScript(
            "if(typeof scrollToHeading==='function'){scrollToHeading(\(blockID));}",
            completionHandler: nil
        )
    }

    var sidebarHidden = false {
        didSet {
            guard isReady, sidebarHidden != oldValue else { return }
            applySidebarHidden()
        }
    }

    /// Widens or narrows the reading column. The template exposes
    /// `setSidebarHidden`; the inline toggle is the fallback used by the
    /// skeleton page when the template is missing from the bundle.
    private func applySidebarHidden() {
        let js = "if(typeof setSidebarHidden==='function'){setSidebarHidden(\(sidebarHidden));}"
            + "else{document.body.classList.toggle('sidebar-hidden', \(sidebarHidden));}"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - PDF

    /// Vector PDF of the page currently in this web view.
    ///
    /// `createPDF` keeps text, table borders, code blocks and KaTeX as real PDF
    /// objects (no bitmap pass). The theme is forced light for the duration: a
    /// dark palette would print a black page.
    func vectorPDF() async throws -> Data {
        let previousAppearance = webView.appearance
        webView.appearance = NSAppearance(named: .aqua)
        await runJS("typeof setForceLight==='function'&&setForceLight(true);")
        // One short turn for `prefers-color-scheme` to be re-resolved before the
        // page is rasterised into PDF operators.
        try? await Task.sleep(nanoseconds: 80_000_000)

        let data: Data
        do {
            data = try await pdfData()
        } catch {
            restoreTheme(previousAppearance)
            throw error
        }
        // Restored before returning: the reader must not keep the light palette
        // for even one frame after a dark-mode export.
        restoreTheme(previousAppearance)
        return data
    }

    /// `createPDF` is completion-handler only in this SDK; the continuation
    /// keeps the export linear and its errors on the caller's side.
    private func pdfData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func restoreTheme(_ appearance: NSAppearance?) {
        webView.appearance = appearance
        webView.evaluateJavaScript(
            "typeof setForceLight==='function'&&setForceLight(false);",
            completionHandler: { _, _ in }
        )
    }

    /// Awaits a fire-and-forget script. The `async` overload of
    /// `evaluateJavaScript` is ambiguous next to the callback one inside an async
    /// method, so the waiting is done explicitly here.
    private func runJS(_ script: String) async {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script, completionHandler: { _, _ in
                continuation.resume()
            })
        }
    }

    /// Offscreen export for a note the reader is not showing (edit mode, or the
    /// web view is not mounted). Same template, same CSS, so the PDF looks like
    /// the page without flashing it on screen.
    static func vectorPDF(for note: LoadedNote, backlinks: [NoteReference], sidebarHidden: Bool) async throws -> Data {
        let controller = MarkdownWebViewController()
        controller.sidebarHidden = sidebarHidden
        await controller.waitUntilReady()
        controller.render(note: note, backlinks: backlinks)
        // The body reaches the template through JavaScript: give it a frame.
        try? await Task.sleep(nanoseconds: 120_000_000)
        return try await controller.vectorPDF()
    }

    /// Polls the template load instead of plumbing a callback: the wait is one
    /// or two frames on a local file, and the timeout only matters when the
    /// bundle is missing.
    private func waitUntilReady(timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !isReady, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    fileprivate func didFinishLoadingSkeleton() {
        isReady = true
        applySidebarHidden()
        if let pendingHTML { self.pendingHTML = nil; setBodyHTML(pendingHTML) }
    }

    func handleSystemMD(url: URL) {
        guard let store else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let value = comps?.queryItems?.first(where: { $0.name == "name" || $0.name == "path" || $0.name == "line" })?.value
        switch url.host {
        case "wikilink": if let value { store.requestWikilinkOpen(value) }
        case "tag": if let value { store.applyTagFilter(value) }
        case "checkbox": if let value, let line = Int(value) { store.toggleTaskCheckbox(atLine: line) }
        case "image": if let value { ImageQuickLook.shared.present(URL(fileURLWithPath: value)) }
        case "note": if let value { store.openNote(at: URL(fileURLWithPath: value)) }
        default: break
        }
    }
}

extension MarkdownWebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !isReady { didFinishLoadingSkeleton(); return }
        // Re-assert the Finder state on every load: a reload of the template
        // starts from a body without the class.
        applySidebarHidden()
        if let pendingHTML { self.pendingHTML = nil; setBodyHTML(pendingHTML) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        if navigationAction.navigationType == .other, (url.scheme == "about" || url.absoluteString == "about:blank" || url.isFileURL) {
            decisionHandler(.allow); return
        }
        if url.scheme == "systemmd" { handleSystemMD(url: url); decisionHandler(.cancel); return }
        if url.scheme == "http" || url.scheme == "https" { NSWorkspace.shared.open(url); decisionHandler(.cancel); return }
        if url.isFileURL { decisionHandler(.allow); return }
        decisionHandler(.allow)
    }
}

extension MarkdownWebViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "openExternal":
            if let s = message.body as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) }
        case "link":
            if let s = message.body as? String, let url = URL(string: s) { handleSystemMD(url: url) }
        case "checkbox":
            if let s = message.body as? String, let line = Int(s) { store?.toggleTaskCheckbox(atLine: line) }
            else if let line = message.body as? Int { store?.toggleTaskCheckbox(atLine: line) }
        case "heading":
            // An empty string means “above the first heading”.
            if let s = message.body as? String { store?.setActiveHeading(Int(s)) }
            else if let id = message.body as? Int { store?.setActiveHeading(id) }
        case "copy":
            if let text = message.body as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        default: break
        }
    }
}

private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

struct MarkdownWebView: NSViewRepresentable {
    let controller: MarkdownWebViewController
    let store: WorkspaceStore
    let note: LoadedNote
    let backlinks: [NoteReference]

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        let webView = controller.webView
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        if webView.superview !== container {
            webView.removeFromSuperview()
            container.addSubview(webView)
        }
        controller.store = store
        controller.sidebarHidden = !store.isSidebarVisible
        controller.render(note: note, backlinks: backlinks)
        MarkdownWebViewController.live = controller
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if controller.webView.superview !== nsView {
            controller.webView.removeFromSuperview()
            controller.webView.frame = nsView.bounds
            controller.webView.autoresizingMask = [.width, .height]
            nsView.addSubview(controller.webView)
        }
        controller.store = store
        controller.sidebarHidden = !store.isSidebarVisible
        controller.render(note: note, backlinks: backlinks)
        MarkdownWebViewController.live = controller
    }
}
