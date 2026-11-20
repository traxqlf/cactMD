import CoreGraphics
import Foundation

/// Builds a notes graph from wikilink metadata only. File contents are read one note at a
/// time inside an autorelease pool and never stored in the resulting graph.
nonisolated enum KnowledgeGraphService {
    // shortcut: byte-level [[...]] scan, so a link inside a code fence is counted.
    // Upgrade to a Markdown AST scan if graph precision matters for code-heavy vaults.
    private static let opening = Data("[[".utf8)
    private static let closing = Data("]]".utf8)

    private struct EdgePair: Hashable {
        let first: URL
        let second: URL

        init(_ lhs: URL, _ rhs: URL) {
            if lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending {
                first = lhs
                second = rhs
            } else {
                first = rhs
                second = lhs
            }
        }
    }

    static func build(from notes: [NoteReference]) -> KnowledgeGraphData {
        guard !notes.isEmpty else { return .empty }

        var lookup: [String: URL] = [:]
        lookup.reserveCapacity(notes.count * 2)
        for note in notes {
            for key in lookupKeys(for: note) where lookup[key] == nil {
                lookup[key] = note.url
            }
        }

        var pairs = Set<EdgePair>()

        for note in notes {
            let targets: [String] = autoreleasepool {
                // Mapped read: contents are dropped when the pool drains.
                guard let data = try? Data(contentsOf: note.url, options: [.mappedIfSafe]),
                      data.range(of: opening) != nil else {
                    return []
                }
                return linkTargets(in: data)
            }

            var seen = Set<URL>()
            for raw in targets {
                guard let target = resolve(raw, lookup: lookup),
                      target != note.url,
                      seen.insert(target).inserted else {
                    continue
                }
                pairs.insert(EdgePair(note.url, target))
            }
        }

        var degree: [URL: Int] = [:]
        for pair in pairs {
            degree[pair.first, default: 0] += 1
            degree[pair.second, default: 0] += 1
        }

        let indexByURL = Dictionary(uniqueKeysWithValues: notes.enumerated().map { ($0.element.url, $0.offset) })
        let indexedEdges: [(Int, Int)] = pairs.compactMap { pair in
            guard let first = indexByURL[pair.first], let second = indexByURL[pair.second] else { return nil }
            return (first, second)
        }
        let points = layout(count: notes.count, edges: indexedEdges)

        let nodes = notes.enumerated().map { index, note in
            let point = points[index]
            return GraphNode(
                id: note.url,
                title: note.name,
                folder: note.folder,
                x: point.x,
                y: point.y,
                degree: degree[note.url] ?? 0
            )
        }
        let edges = indexedEdges.map { pair in
            GraphEdge(source: notes[pair.0].url, target: notes[pair.1].url)
        }

        return KnowledgeGraphData(
            nodes: nodes,
            edges: edges,
            nodesByID: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        )
    }

    // MARK: - Wikilinks

    private static func lookupKeys(for note: NoteReference) -> [String] {
        let relative = normalize(note.relativePathWithoutExtension)
        var keys = [normalize(note.name), relative]
        let lastComponent = relative.split(separator: "/").last.map(String.init) ?? relative
        keys.append(lastComponent)
        return keys.filter { !$0.isEmpty }
    }

    private static func resolve(_ raw: String, lookup: [String: URL]) -> URL? {
        let normalized = normalize(raw)
        if let direct = lookup[normalized] {
            return direct
        }
        guard let lastComponent = normalized.split(separator: "/").last.map(String.init),
              !lastComponent.isEmpty else {
            return nil
        }
        return lookup[lastComponent]
    }

    private static func normalize(_ raw: String) -> String {
        var value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        while value.hasPrefix("./") {
            value.removeFirst(2)
        }
        if value.hasSuffix(".markdown") {
            value = String(value.dropLast(9))
        } else if value.hasSuffix(".md") {
            value = String(value.dropLast(3))
        }
        return value
    }

    private static func linkTargets(in data: Data) -> [String] {
        var targets: [String] = []
        var searchStart = data.startIndex

        while searchStart < data.endIndex,
              let openRange = data.range(of: opening, options: [], in: searchStart..<data.endIndex) {
            let contentStart = openRange.upperBound
            guard contentStart < data.endIndex,
                  let closeRange = data.range(of: closing, options: [], in: contentStart..<data.endIndex) else {
                break
            }

            var content = data[contentStart..<closeRange.lowerBound]
            if content.contains(UInt8(ascii: "[")) {
                searchStart = closeRange.upperBound
                continue
            }
            if let pipe = content.firstIndex(of: UInt8(ascii: "|")) {
                content = content[..<pipe]
            }
            if let heading = content.firstIndex(of: UInt8(ascii: "#")) {
                content = content[..<heading]
            }

            if let raw = String(data: content, encoding: .utf8) {
                let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !target.isEmpty {
                    targets.append(target)
                }
            }
            searchStart = closeRange.upperBound
        }

        return targets
    }

    // MARK: - Layout

    private static func layout(count: Int, edges: [(Int, Int)]) -> [CGPoint] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [.zero] }

        // Golden-angle spiral: deterministic and already free of clumps before the forces run.
        var points = (0..<count).map { index -> CGPoint in
            let angle = Double(index) * 2.399_963_229_728_653
            let radius = 0.12 + 0.8 * sqrt(Double(index + 1) / Double(count))
            return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }

        let iterations = count > 700 ? 22 : (count > 250 ? 42 : 72)
        let idealDistance = 1.3 / sqrt(Double(count))
        var temperature = 0.18

        for _ in 0..<iterations {
            var forces = [CGPoint](repeating: .zero, count: count)

            for first in 0..<count {
                for second in (first + 1)..<count {
                    var dx = points[first].x - points[second].x
                    var dy = points[first].y - points[second].y
                    var distanceSquared = dx * dx + dy * dy
                    if distanceSquared < 0.000_001 {
                        dx = 0.001
                        dy = 0.001
                        distanceSquared = dx * dx + dy * dy
                    }
                    let distance = sqrt(distanceSquared)
                    let repulsion = (idealDistance * idealDistance) / distance
                    let fx = dx / distance * repulsion
                    let fy = dy / distance * repulsion
                    forces[first].x += fx
                    forces[first].y += fy
                    forces[second].x -= fx
                    forces[second].y -= fy
                }
            }

            for (source, target) in edges {
                let dx = points[target].x - points[source].x
                let dy = points[target].y - points[source].y
                let distance = max(sqrt(dx * dx + dy * dy), 0.001)
                let attraction = (distance * distance) / idealDistance * 0.12
                let fx = dx / distance * attraction
                let fy = dy / distance * attraction
                forces[source].x += fx
                forces[source].y += fy
                forces[target].x -= fx
                forces[target].y -= fy
            }

            for index in 0..<count {
                let stepX = min(max(forces[index].x, -temperature), temperature)
                let stepY = min(max(forces[index].y, -temperature), temperature)
                points[index].x = min(max(points[index].x + stepX, -1.5), 1.5)
                points[index].y = min(max(points[index].y + stepY, -1.5), 1.5)
            }
            temperature *= 0.93
        }

        var maxExtent: CGFloat = 0.0001
        for point in points {
            maxExtent = max(maxExtent, abs(point.x), abs(point.y))
        }
        let scale = 0.92 / maxExtent
        return points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
    }
}
