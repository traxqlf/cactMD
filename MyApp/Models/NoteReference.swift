import Foundation

nonisolated struct NoteReference: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let relativePath: String
    let folder: String

    var id: URL { url }

    var relativePathWithoutExtension: String {
        let lowercased = relativePath.lowercased()
        if lowercased.hasSuffix(".markdown") {
            return String(relativePath.dropLast(9))
        }
        if lowercased.hasSuffix(".md") {
            return String(relativePath.dropLast(3))
        }
        return relativePath
    }
}

nonisolated struct NoteHeading: Identifiable, Sendable {
    let id: Int
    let level: Int
    let title: String
}
