import CoreServices
import Foundation

nonisolated final class FSEventsWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.systemmd.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?
    private var debounceWorkItem: DispatchWorkItem?
    private var pendingPaths: Set<String> = []
    /// Root the stream was started with, used to drop sidecar churn (`.git`,
    /// `.obsidian`, `~`/`.tmp` writes, exports) before it reaches the store.
    private var rootPath: String = ""
    private let debounceMilliseconds: Int
    private let onChange: @Sendable (Set<String>) -> Void

    init(debounceMilliseconds: Int = 850, onChange: @escaping @Sendable (Set<String>) -> Void) {
        self.debounceMilliseconds = debounceMilliseconds
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start(watching url: URL) {
        stop()

        let path = url.path
        queue.sync { rootPath = path }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )

        guard let createdStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            CFTimeInterval(0.04),
            flags
        ) else {
            return
        }

        stream = createdStream
        FSEventStreamSetDispatchQueue(createdStream, queue)
        FSEventStreamStart(createdStream)
    }

    func stop() {
        queue.sync {
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
            pendingPaths.removeAll()
        }

        guard let activeStream = stream else { return }
        stream = nil
        FSEventStreamStop(activeStream)
        FSEventStreamInvalidate(activeStream)
        FSEventStreamRelease(activeStream)
    }

    fileprivate func handleEvents(paths: [String]) {
        let root = rootPath
        for path in paths where Self.isRelevant(path: path, root: root) {
            pendingPaths.insert(path)
        }
        guard !pendingPaths.isEmpty else { return }

        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = self.pendingPaths
            self.pendingPaths.removeAll()
            guard !batch.isEmpty else { return }
            self.onChange(batch)
        }
        debounceWorkItem = workItem
        queue.asyncAfter(
            deadline: .now() + .milliseconds(debounceMilliseconds),
            execute: workItem
        )
    }

    /// A sync client (iCloud, Git, Obsidian, Finder) writes hundreds of sidecar
    /// files per burst. None of them can change the note list: only visible
    /// folders and Markdown files are forwarded.
    fileprivate static func isRelevant(path: String, root: String) -> Bool {
        guard !root.isEmpty else { return true }
        guard path != root else { return false }

        let relative: String
        if path.hasPrefix(root + "/") {
            relative = String(path.dropFirst(root.count + 1))
        } else {
            relative = path
        }
        guard !relative.isEmpty else { return false }

        for component in relative.split(separator: "/") {
            // `.git`, `.obsidian`, `.trash`, `.DS_Store`, `.tmp…`: never ours.
            if component.hasPrefix(".") { return false }
            if component.hasSuffix("~") { return false }
            let lowercased = component.lowercased()
            if lowercased.hasSuffix(".tmp") || lowercased.hasSuffix(".temp") || lowercased.hasSuffix(".swp") {
                return false
            }
        }

        let name = relative.split(separator: "/").last.map(String.init) ?? relative
        let pathExtension = (name as NSString).pathExtension.lowercased()
        // No extension: a folder (or a folder being moved), which does matter.
        guard !pathExtension.isEmpty else { return true }
        // PDFs never change the note index, but they do change the sidebar: an
        // added, renamed or deleted PDF must refresh the tree.
        return pathExtension == "md" || pathExtension == "markdown" || pathExtension == "pdf"
    }
}

private nonisolated let fsEventsCallback: FSEventStreamCallback = {
    _,
    clientCallBackInfo,
    _,
    eventPaths,
    _,
    _ in
    guard let info = clientCallBackInfo else { return }
    let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
    let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    guard let paths = cfArray as? [String], !paths.isEmpty else { return }
    watcher.handleEvents(paths: paths)
}
