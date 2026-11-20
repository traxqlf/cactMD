import Foundation

/// Metadata-only graph. Note contents are never retained: the builder reads each file,
/// extracts wikilink targets, then releases the bytes.
nonisolated struct GraphNode: Identifiable, Sendable {
    let id: URL
    let title: String
    let folder: String
    let x: Double
    let y: Double
    let degree: Int
}

nonisolated struct GraphEdge: Identifiable, Sendable {
    let source: URL
    let target: URL

    var id: String { "\(source.path)\u{0}\(target.path)" }
}

nonisolated struct KnowledgeGraphData: Sendable {
    let nodes: [GraphNode]
    let edges: [GraphEdge]
    let nodesByID: [URL: GraphNode]

    static let empty = KnowledgeGraphData(nodes: [], edges: [], nodesByID: [:])
}
