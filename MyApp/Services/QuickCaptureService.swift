import Foundation

/// Turns the selected text of any app (Services menu) into a dated note.
///
/// Everything lands in `<vault>/Inbox/Capture-YYYY-MM-DD.md`: one file per day,
/// so a day of captures reads as a single timeline instead of dozens of notes.
/// `Inbox/` is created on the first capture and then left alone — the user can
/// move it, rename it, or keep filing notes out of it.
enum QuickCaptureService {
    static let inboxFolderName = "Inbox"

    enum CaptureError: LocalizedError {
        case emptyText
        case notADirectory(URL)

        var errorDescription: String? {
            switch self {
            case .emptyText:
                return "Aucun texte à capturer."
            case .notADirectory(let url):
                return "« \(url.lastPathComponent) » n'est pas un dossier."
            }
        }
    }

    /// Appends `text` under a `## HH:mm` heading and returns the daily note.
    ///
    /// The existing file is extended through `FileHandle`, never rewritten: the
    /// capture note is usually still open in the app, and a rewrite would race
    /// the editor's own atomic saves.
    static func append(_ text: String, to root: URL, date: Date = Date()) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CaptureError.emptyText }

        let fileManager = FileManager.default
        let inbox = root.appendingPathComponent(inboxFolderName, isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: inbox.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CaptureError.notADirectory(inbox) }
        } else {
            try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        }

        let day = dayFormatter.string(from: date)
        let url = inbox.appendingPathComponent("Capture-\(day).md")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        var entry = ""
        if existing.isEmpty {
            entry = "# Capture \(day)\n\n"
        } else if !existing.hasSuffix("\n\n") {
            entry = existing.hasSuffix("\n") ? "\n" : "\n\n"
        }
        entry += "## \(timeFormatter.string(from: date))\n\n\(trimmed)\n\n"

        if existing.isEmpty {
            try entry.write(to: url, atomically: true, encoding: .utf8)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(entry.utf8))
        }
        return url
    }

    /// Fixed identifiers: a captured date must not follow the user's locale or
    /// calendar, or two captures of the same day could land in two files.
    private static let dayFormatter = makeFormatter("yyyy-MM-dd")
    private static let timeFormatter = makeFormatter("HH:mm")

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }
}
