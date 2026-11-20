import Foundation

nonisolated enum FileTreeIndexer {
    /// Heavy development folders that must never be crawled, even inside a
    /// folder the user picked as their root.
    static let excludedDirectoryNames: Set<String> = [
        ".git", "node_modules", "build", "DerivedData", ".build"
    ]

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .contentModificationDateKey,
        .nameKey
    ]

    /// Depth-1 listing only: one `contentsOfDirectory` call, no recursion. This
    /// is what lets a huge or iCloud-synced folder paint immediately.
    static func shallowScan(rootURL: URL) -> IndexedNode? {
        let resolvedRoot = rootURL.resolvingSymlinksInPath()
        guard let rootValues = try? resolvedRoot.resourceValues(forKeys: resourceKeys),
              rootValues.isDirectory == true else {
            return nil
        }

        let isPackage = rootValues.isPackage == true
        return IndexedNode(
            url: resolvedRoot,
            name: rootValues.name ?? resolvedRoot.lastPathComponent,
            isDirectory: !isPackage,
            modificationDate: rootValues.contentModificationDate,
            children: shallowChildren(of: resolvedRoot)
        )
    }

    /// Direct children of `url`, sorted folders first. Safe to call on demand
    /// when a folder is expanded or opened in the icon grid. Always lists every
    /// non-excluded subdirectory, even when it contains no `.md` file at its
    /// root; the path is resolved so iCloud-backed locations (e.g. ~/Documents)
    /// enumerate reliably.
    static func shallowChildren(of url: URL) -> [IndexedNode] {
        let resolvedURL = url.resolvingSymlinksInPath()
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: resolvedURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )) ?? []

        var children: [IndexedNode] = []
        children.reserveCapacity(contents.count)

        for childURL in contents {
            let resolvedChild = childURL.resolvingSymlinksInPath()
            guard let childValues = try? resolvedChild.resourceValues(forKeys: resourceKeys),
                  childValues.isSymbolicLink != true else {
                continue
            }

            let childIsDir = (childValues.isDirectory == true) && (childValues.isPackage != true)
            if childIsDir {
                guard !excludedDirectoryNames.contains(resolvedChild.lastPathComponent) else { continue }
            } else if !isDisplayableFile(resolvedChild) {
                continue
            }

            children.append(
                IndexedNode(
                    url: resolvedChild,
                    name: childValues.name ?? resolvedChild.lastPathComponent,
                    isDirectory: childIsDir,
                    modificationDate: childValues.contentModificationDate,
                    children: []
                )
            )
        }

        children.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return children
    }

    /// Streaming walk that collects Markdown notes only. It never materialises
    /// the folder tree: a vault with 76 000 files costs one pass and one small
    /// array of references, which is what search, tags and the graph need.
    static func scanNotes(rootURL: URL) -> [NoteReference] {
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        var references: [NoteReference] = []

        // A directory enumerator batches its `getattrlist` calls, which is far
        // cheaper than one `resourceValues` round-trip per entry.
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var visited = 0
        while let entry = enumerator.nextObject() {
            visited += 1
            // Cancellation is checked in batches: this runs off the main thread
            // and the check must stay cheap.
            if visited % 128 == 0, Task.isCancelled { return [] }

            autoreleasepool {
                guard let childURL = entry as? URL,
                      let values = try? childURL.resourceValues(forKeys: resourceKeys),
                      values.isSymbolicLink != true else {
                    return
                }

                if (values.isDirectory == true) && (values.isPackage != true) {
                    if excludedDirectoryNames.contains(childURL.lastPathComponent) {
                        enumerator.skipDescendants()
                    }
                    return
                }

                guard isMarkdownFile(childURL) else { return }
                let relativePath = childURL.path.hasPrefix(prefix)
                    ? String(childURL.path.dropFirst(prefix.count))
                    : childURL.lastPathComponent
                references.append(
                    NoteReference(
                        url: childURL,
                        name: childURL.deletingPathExtension().lastPathComponent,
                        relativePath: relativePath,
                        folder: (relativePath as NSString).deletingLastPathComponent
                    )
                )
            }
        }

        return references.sorted { lhs, rhs in
            if lhs.name != rhs.name {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    static func isMarkdownFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    /// PDFs are readable in a tab, but they are deliberately not notes: they
    /// never enter `allNotes`, the render cache or the tag/graph passes.
    static func isPDFFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    /// The only two kinds of file a tab can show.
    static func isOpenableFile(_ url: URL) -> Bool {
        isMarkdownFile(url) || isPDFFile(url)
    }

    private static let previewableExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "webp", "bmp", "svg", "pdf"
    ]

    static func isDisplayableFile(_ url: URL) -> Bool {
        if isMarkdownFile(url) { return true }
        return previewableExtensions.contains(url.pathExtension.lowercased())
    }
}
