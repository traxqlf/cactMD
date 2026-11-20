import Foundation

/// Spotlight-backed *candidate* lookup for the full-text palette.
///
/// `NSMetadataQuery` answers from the already-built `mds` index instead of
/// walking the vault, so a query over thousands of notes comes back in a few
/// milliseconds and costs no disk reads. The index only knows *that* a note
/// matches, not which line does, so the palette still extracts its snippets from
/// the handful of candidate files (see `FullTextSearchService.hits`).
///
/// Every entry point is called from the main thread, which is also where
/// `NSMetadataQuery` delivers its notifications. The query is torn down as soon
/// as it has answered — on success, on timeout and on cancellation — so a closed
/// palette leaves no live query and no periodic CPU behind.
final class SpotlightSearchService {
    static let shared = SpotlightSearchService()

    /// A gather pass that has not finished by then is abandoned: Spotlight is
    /// either still indexing or the vault sits on a volume without an index, and
    /// in both cases the caller's own scan is the better answer.
    private static let timeout: TimeInterval = 0.45

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var pending: CheckedContinuation<[URL], Never>?
    private var pendingLimit = 400

    private init() {}

    /// Markdown notes under `root` whose name or indexed content matches `text`.
    func candidateURLs(for text: String, in root: URL, limit: Int = 400) async -> [URL] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        stop()

        let query = NSMetadataQuery()
        query.searchScopes = [root]
        // `*` and `?` are LIKE wildcards even inside the argument: escaping them
        // keeps a query such as "50 % *" from matching every note.
        //
        // The extension filter is written as `LIKE[cd] "*.md"` rather than the
        // `== "*.md"c` form: this Foundation refuses to parse a quoted literal
        // followed by the `c` modifier, and a predicate that does not parse
        // raises instead of returning nothing.
        let pattern = "*" + Self.escapedLikePattern(needle) + "*"
        query.predicate = NSPredicate(
            format: "kMDItemFSName LIKE[cd] %@ AND (kMDItemTextContent LIKE[cd] %@ OR kMDItemFSName LIKE[cd] %@)",
            "*.md",
            pattern,
            pattern
        )
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)]
        self.query = query
        defer { stop() }

        return await withCheckedContinuation { continuation in
            pending = continuation
            pendingLimit = limit

            observers.append(NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: .main
            ) { [weak self] _ in
                self?.finish()
            })

            // The index may stay silent on an unindexed volume: never leave the
            // palette spinning on a query that will not answer.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
                self?.finish()
            }

            query.start()
        }
    }

    /// Ends the live query and drops its observers: after this the service costs
    /// nothing until the next search.
    func stop() {
        query?.stop()
        query = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()

        // Whoever is waiting gets the empty answer rather than hanging on a
        // query that no longer exists.
        resume(with: [])
    }

    // MARK: - Private

    /// Single exit point for the notification and the timeout: the second one to
    /// arrive finds no pending continuation and does nothing.
    private func finish() {
        guard let query, pending != nil else { return }
        query.disableUpdates()
        resume(with: paths(in: query, limit: pendingLimit))
    }

    private func resume(with urls: [URL]) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: urls)
    }

    private func paths(in query: NSMetadataQuery, limit: Int) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        for item in query.results {
            guard let metadata = item as? NSMetadataItem,
                  let path = metadata.value(forAttribute: NSMetadataItemPathKey) as? String,
                  path.lowercased().hasSuffix(".md"),
                  seen.insert(path).inserted else { continue }
            urls.append(URL(fileURLWithPath: path))
            if urls.count >= limit { break }
        }
        return urls
    }

    private static func escapedLikePattern(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count + 8)
        for character in text {
            switch character {
            case "\\", "*", "?":
                output.append("\\")
                output.append(character)
            default:
                output.append(character)
            }
        }
        return output
    }
}
