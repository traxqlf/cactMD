import AppKit
import Observation
import UniformTypeIdentifiers

/// Provides file and folder icons using native Finder/workspace icons.
@MainActor
@Observable
final class FileIconProvider {
    static let shared = FileIconProvider()

    private static let maxFolderIcons = 1024

    /// Coloured Finder dot used by the tag menus, drawn rather than symbolised:
    /// both AppKit and SwiftUI menus ignore palette tints and would show a plain
    /// grey circle. Index 0 ("no tag") has no dot at all.
    nonisolated static func tagDotImage(for label: Int, checked: Bool = false) -> NSImage? {
        let colors: [NSColor] = [
            .clear, .systemGray, .systemGreen, .systemPurple,
            .systemBlue, .systemYellow, .systemRed, .systemOrange
        ]
        guard label > 0, colors.indices.contains(label) else { return nil }

        let image = NSImage(size: NSSize(width: 13, height: 13), flipped: false) { rect in
            colors[label].setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()

            // A tagged row shows its own dot *and* the check, so the colour is
            // never traded away for the "this one is set" affordance.
            if checked {
                let mark = "✓" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 9),
                    .foregroundColor: NSColor.white
                ]
                let size = mark.size(withAttributes: attributes)
                mark.draw(
                    at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2),
                    withAttributes: attributes
                )
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    @ObservationIgnored private var typeIcons: [String: NSImage] = [:]
    @ObservationIgnored private var resolvedPathCache: [URL: String] = [:]
    private var folderIcons: [String: NSImage] = [:]

    @ObservationIgnored private var pendingURLs: [URL] = []
    @ObservationIgnored private var pendingSet: Set<URL> = []
    @ObservationIgnored private var isResolving = false

    private init() {
        typeIcons["__folder__"] = NSWorkspace.shared.icon(for: .folder)
    }

    func icon(for node: FileNode) -> NSImage {
        icon(for: node.url, isDirectory: node.isDirectory)
    }

    func icon(for url: URL, isDirectory: Bool) -> NSImage {
        if isDirectory {
            let path = cachedResolvedPath(for: url)
            return folderIcons[path] ?? typeIcon(for: .folder, key: "__folder__")
        }

        let ext = url.pathExtension.lowercased()
        if let cached = typeIcons[ext] {
            return cached
        }

        let type = Self.contentType(forExtension: ext)
        let icon = typeIcon(for: type, key: ext)
        typeIcons[ext] = icon
        return icon
    }

    func prefetch(_ nodes: [FileNode]) {
        guard !nodes.isEmpty else { return }
        prefetchDirectoryURLs(nodes.filter(\.isDirectory).map(\.url))
    }

    func prefetchDirectoryURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var immediateBatch: [URL] = []

        for url in urls {
            let resolved = url.resolvingSymlinksInPath()
            resolvedPathCache[url] = resolved.path

            if folderIcons[resolved.path] == nil, !pendingSet.contains(resolved) {
                if immediateBatch.count < 30 {
                    immediateBatch.append(resolved)
                } else {
                    pendingSet.insert(resolved)
                    pendingURLs.append(resolved)
                }
            }
        }

        for url in immediateBatch {
            resolveOne(url)
        }
        if !pendingURLs.isEmpty {
            startResolving()
        }
    }

    func invalidate(urls: [URL]) {
        guard !urls.isEmpty else { return }
        for url in urls {
            let resolved = url.resolvingSymlinksInPath()
            let path = resolved.path
            resolvedPathCache[url] = path
            folderIcons.removeValue(forKey: path)
            if pendingSet.insert(resolved).inserted {
                pendingURLs.append(resolved)
            }
        }
        startResolving()
    }

    func invalidateAllFolderIcons() {
        folderIcons.removeAll(keepingCapacity: true)
        resolvedPathCache.removeAll(keepingCapacity: true)
    }

    private func cachedResolvedPath(for url: URL) -> String {
        if let cached = resolvedPathCache[url] {
            return cached
        }
        return url.path
    }

    private func typeIcon(for type: UTType, key: String) -> NSImage {
        if let cached = typeIcons[key] { return cached }
        let icon = NSWorkspace.shared.icon(for: type)
        typeIcons[key] = icon
        return icon
    }

    private func resolveOne(_ resolved: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        let path = resolved.path
        guard folderIcons[path] == nil else { return }

        if folderIcons.count >= Self.maxFolderIcons {
            folderIcons.removeAll(keepingCapacity: true)
        }

        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.isTemplate = false
        folderIcons[path] = icon
    }

    private func startResolving() {
        guard !isResolving, !pendingURLs.isEmpty else { return }
        isResolving = true

        Task { [weak self] in
            while let self, !self.pendingURLs.isEmpty {
                let resolved = self.pendingURLs.removeFirst()
                self.pendingSet.remove(resolved)
                self.resolveOne(resolved)
                await Task.yield()
            }
            self?.isResolving = false
        }
    }

    private static func contentType(forExtension ext: String) -> UTType {
        guard !ext.isEmpty else { return .data }
        switch ext {
        case "md", "markdown", "txt":
            return .plainText
        default:
            return UTType(filenameExtension: ext) ?? .data
        }
    }
}
