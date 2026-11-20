import AppKit
import Foundation

enum BookmarkStore {
    private static let bookmarkKey = "systemmd.rootFolderBookmark"
    private static let pathKey = "systemmd.rootFolderPath"

    static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choisir"
        panel.message = "Sélectionnez le dossier racine de vos fichiers Markdown"

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }
        save(url: url)
        return url
    }

    static func save(url: URL) {
        let defaults = UserDefaults.standard
        defaults.set(url.path, forKey: pathKey)
        if let data = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(data, forKey: bookmarkKey)
        }
    }

    static func restore() -> URL? {
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: bookmarkKey) {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: data,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), directoryExists(at: resolved) {
                if isStale {
                    save(url: resolved)
                }
                return resolved
            }
        }

        if let path = defaults.string(forKey: pathKey) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if directoryExists(at: url) {
                save(url: url)
                return url
            }
        }

        return nil
    }

    private static func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
