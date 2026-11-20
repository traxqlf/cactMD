import Foundation

nonisolated struct IndexedNode: Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let modificationDate: Date?
    let children: [IndexedNode]
}

final class FileNode: Identifiable {
    let id: URL
    var url: URL
    var name: String
    let isDirectory: Bool
    var modificationDate: Date?
    var children: [FileNode]

    init(
        url: URL,
        name: String,
        isDirectory: Bool,
        modificationDate: Date?,
        children: [FileNode] = []
    ) {
        self.id = url
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.modificationDate = modificationDate
        self.children = children
    }

    func flattenedNodesByURL(into map: inout [URL: FileNode]) {
        map[url] = self
        for child in children {
            child.flattenedNodesByURL(into: &map)
        }
    }

    static func reconcile(from indexed: IndexedNode, existingByURL: [URL: FileNode]) -> FileNode {
        let existing = existingByURL[indexed.url]
        let node: FileNode
        if let existing, existing.isDirectory == indexed.isDirectory {
            existing.name = indexed.name
            existing.modificationDate = indexed.modificationDate
            node = existing
        } else {
            node = FileNode(
                url: indexed.url,
                name: indexed.name,
                isDirectory: indexed.isDirectory,
                modificationDate: indexed.modificationDate
            )
        }
        if indexed.children.isEmpty {
            // Preserve already-loaded subtrees instead of wiping them with [].
            if let existing, !existing.children.isEmpty {
                node.children = existing.children
            } else {
                node.children = []
            }
        } else {
            node.children = indexed.children.map {
                reconcile(from: $0, existingByURL: existingByURL)
            }
        }
        return node
    }
}
