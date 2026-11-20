import Foundation

/// Snapshot of one editor tab. The workspace keeps the live note state and saves it here
/// whenever the active tab changes, so each tab restores its note, mode and scroll position.
struct WorkspaceTab: Identifiable, Equatable {
    let id: UUID
    var noteURL: URL?
    var isEditing: Bool
    var editorText: String
    var topBlockID: Int?
    var backStack: [URL]
    var forwardStack: [URL]

    init(
        id: UUID = UUID(),
        noteURL: URL? = nil,
        isEditing: Bool = false,
        editorText: String = "",
        topBlockID: Int? = nil,
        backStack: [URL] = [],
        forwardStack: [URL] = []
    ) {
        self.id = id
        self.noteURL = noteURL
        self.isEditing = isEditing
        self.editorText = editorText
        self.topBlockID = topBlockID
        self.backStack = backStack
        self.forwardStack = forwardStack
    }
}
