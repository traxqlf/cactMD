import Foundation

/// In-memory LRU of already rendered notes.
///
/// The reader used to pay a disk read, a `cmark-gfm` parse and an
/// `AttributedString` build for every single open, so going back and forth
/// between two notes re-parsed both of them every time. A hit here hands the
/// exact blocks the previous render produced, which makes switching between
/// already seen notes a dictionary lookup instead of work.
///
/// The cache is sized for a fast reading session: 80 rendered notes and a
/// 50 MB byte budget. That is enough to hold every note in `recentNotes`
/// (20) several times over, so a click in the sidebar never waits for disk or
/// `cmark-gfm`. Least recently used entries are evicted first.
nonisolated final class NoteRenderCache: @unchecked Sendable {
    struct Render: @unchecked Sendable {
        let note: LoadedNote
        /// Raw Markdown, kept so ⌘⇧E can open the editor without re-reading the
        /// file (a mapped read still costs a syscall per megabyte).
        let text: String
        /// False while word count, outline and tags are still being measured in
        /// the background: a hit then re-schedules that pass instead of
        /// showing zeros for the rest of the session.
        let hasSecondaryMetadata: Bool
        let cost: Int
        /// Stamped on every hit and every store: the idle purge uses it to keep
        /// what the user is working on and drop what they merely visited.
        var lastAccess: Date
    }

    static let shared = NoteRenderCache()

    static let maxEntries = 80
    /// Generous budget: an extra 50 MB is acceptable for instant navigation.
    static let maxCost = 50 * 1024 * 1024

    private let lock = NSLock()
    private var entries: [String: Render] = [:]
    /// Least recently used first.
    private var recency: [String] = []
    private var totalCost = 0

    init() {}

    /// Canonical key (`realpath`) so a symlinked path cannot hold a second copy
    /// of the same note.
    static func key(for url: URL) -> String {
        guard let resolved = url.path.withCString({ realpath($0, nil) }) else {
            return url.standardizedFileURL.path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func render(for url: URL, validatingModificationDate: Bool = true) -> Render? {
        let key = Self.key(for: url)

        lock.lock()
        let cached = entries[key]
        lock.unlock()
        guard let cached else { return nil }

        // One stat is all the disk validation a hit costs. The content and the
        // parse are reused as long as the modification date on disk is the one
        // the render was built from.
        if validatingModificationDate {
            let current = Self.modificationDate(of: url)
            if let known = cached.note.modificationDate {
                guard current == known else {
                    remove(key: key)
                    return nil
                }
            } else if current == nil {
                // The file is gone: never serve its blocks again.
                remove(key: key)
                return nil
            }
        }

        lock.lock()
        guard var live = entries[key] else {
            lock.unlock()
            return nil
        }
        live.lastAccess = Date()
        entries[key] = live
        touchLocked(key)
        lock.unlock()
        return live
    }

    func store(note: LoadedNote, text: String, hasSecondaryMetadata: Bool) {
        let key = Self.key(for: note.url)
        let cost = Self.cost(text: text, blocks: note.blocks)

        lock.lock()
        defer { lock.unlock() }

        if let previous = entries[key] {
            totalCost -= previous.cost
        }
        recency.removeAll { $0 == key }
        entries[key] = Render(
            note: note,
            text: text,
            hasSecondaryMetadata: hasSecondaryMetadata,
            cost: cost,
            lastAccess: Date()
        )
        recency.append(key)
        totalCost += cost
        trimLocked()
    }

    /// Membership without a stat: used by the silent prewarm to skip notes it
    /// already holds. A stale entry is still validated on the next real open.
    func contains(_ url: URL) -> Bool {
        let key = Self.key(for: url)
        lock.lock()
        defer { lock.unlock() }
        return entries[key] != nil
    }

    func remove(url: URL) {
        remove(key: Self.key(for: url))
    }

    /// Called with the paths FSEvents reported. External writes, renames and
    /// deletions must never leave a stale render behind.
    func invalidate(paths: Set<String>) {
        guard !paths.isEmpty else { return }
        var candidates = paths
        // FSEvents reports the paths it was started with, which are already
        // canonical for a normally opened folder; resolving is only worth it
        // for small bursts (a bulk copy would cost thousands of syscalls).
        if paths.count <= 32 {
            for path in paths {
                candidates.insert(Self.key(for: URL(fileURLWithPath: path)))
            }
        }
        for candidate in candidates {
            remove(key: candidate)
        }
    }

    /// Soft background cleanup: drops every render that is not in `keeping` and
    /// has not been touched for `interval`.
    ///
    /// Called when the app resigns active and by a five-minute housekeeping
    /// timer, so an idle session does not keep the whole vault parsed in memory.
    /// Returns how many entries went away, for the debug log.
    @discardableResult
    func purge(keeping keepingKeys: Set<String>, olderThan interval: TimeInterval) -> Int {
        let cutoff = Date().addingTimeInterval(-max(0, interval))

        lock.lock()
        defer { lock.unlock() }

        let stale = entries.compactMap { key, entry in
            entry.lastAccess < cutoff && !keepingKeys.contains(key) ? key : nil
        }
        for key in stale {
            if let removed = entries.removeValue(forKey: key) {
                totalCost -= removed.cost
            }
        }
        if !stale.isEmpty {
            recency.removeAll { entries[$0] == nil }
        }
        return stale.count
    }

    func removeAll() {
        lock.lock()
        entries.removeAll()
        recency.removeAll()
        totalCost = 0
        lock.unlock()
    }

    #if DEBUG
    var debugSummary: String {
        lock.lock()
        defer { lock.unlock() }
        return "\(entries.count) notes, \(totalCost / 1024) KB"
    }
    #endif

    // MARK: - Private

    private func touchLocked(_ key: String) {
        guard let index = recency.firstIndex(of: key) else { return }
        recency.remove(at: index)
        recency.append(key)
    }

    private func remove(key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let removed = entries.removeValue(forKey: key) else { return }
        totalCost -= removed.cost
        recency.removeAll { $0 == key }
    }

    private func trimLocked() {
        while recency.count > Self.maxEntries || (totalCost > Self.maxCost && recency.count > 1) {
            let oldest = recency.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                totalCost -= removed.cost
            }
        }
        if totalCost > Self.maxCost, let only = recency.first, let removed = entries.removeValue(forKey: only) {
            // A single note bigger than the whole budget is not worth caching:
            // its blocks still live in `loadedNote`.
            totalCost -= removed.cost
            recency.removeFirst()
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Rough footprint: the raw text, the attributed runs built from it and a
    /// per-block constant for the Swift values themselves.
    private static func cost(text: String, blocks: [MarkdownBlock]) -> Int {
        text.utf8.count * 4 + blockCount(blocks) * 256
    }

    private static func blockCount(_ blocks: [MarkdownBlock]) -> Int {
        var count = 0
        func walk(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                count += 1
                switch block.kind {
                case .blockQuote(let nested):
                    walk(nested)
                case .list(_, _, let items):
                    for item in items {
                        walk(item.blocks)
                    }
                default:
                    break
                }
            }
        }
        walk(blocks)
        return count
    }
}
