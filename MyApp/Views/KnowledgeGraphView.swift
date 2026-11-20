import SwiftUI

struct KnowledgeGraphView: View {
    @Bindable var store: WorkspaceStore

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var committedPan: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var hoveredID: URL?
    @State private var neighborIDs: Set<URL> = []

    var body: some View {
        Group {
            if store.isGraphLoading, store.graphData == nil {
                loadingState
            } else if let data = store.graphData, !data.nodes.isEmpty {
                graphCanvas(data)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .onAppear {
            store.ensureGraphLoaded()
        }
    }

    // MARK: - Canvas

    private func graphCanvas(_ data: KnowledgeGraphData) -> some View {
        GeometryReader { proxy in
            let radius = min(proxy.size.width, proxy.size.height) * 0.42 * zoom

            Canvas { context, size in
                draw(data: data, context: &context, size: size, radius: radius)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    updateHover(
                        at: location,
                        data: data,
                        size: proxy.size,
                        radius: radius
                    )
                case .ended:
                    setHovered(nil, data: data)
                }
            }
            .gesture(panGesture)
            .simultaneousGesture(zoomGesture)
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        if let node = node(at: value.location, data: data, size: proxy.size, radius: radius) {
                            store.openGraphNode(node.id)
                        }
                    }
            )
            .overlay(alignment: .topLeading) {
                header(data)
            }
            .overlay(alignment: .topTrailing) {
                controls
            }
            .overlay(alignment: .bottom) {
                hint
            }
            .accessibilityLabel("Graphe des notes")
        }
    }

    private func draw(
        data: KnowledgeGraphData,
        context: inout GraphicsContext,
        size: CGSize,
        radius: CGFloat
    ) {
        let center = CGPoint(
            x: size.width / 2 + pan.width,
            y: size.height / 2 + pan.height
        )
        let hovered = hoveredID
        let dotRadius = min(max(4.5 * sqrt(zoom), 4), 9)

        func screenPoint(_ node: GraphNode) -> CGPoint {
            CGPoint(
                x: center.x + CGFloat(node.x) * radius,
                y: center.y + CGFloat(node.y) * radius
            )
        }

        for edge in data.edges {
            guard let source = data.nodesByID[edge.source],
                  let target = data.nodesByID[edge.target] else {
                continue
            }
            let highlighted = hovered != nil
                && (edge.source == hovered || edge.target == hovered)

            var path = Path()
            path.move(to: screenPoint(source))
            path.addLine(to: screenPoint(target))
            context.stroke(
                path,
                with: .color(highlighted ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.16)),
                lineWidth: highlighted ? 1.6 : 1
            )
        }

        for node in data.nodes {
            let point = screenPoint(node)
            let isHovered = node.id == hovered
            let isNeighbor = neighborIDs.contains(node.id)
            let nodeRadius = dotRadius * (1 + min(CGFloat(node.degree), 8) * 0.05)
            let rect = CGRect(
                x: point.x - nodeRadius,
                y: point.y - nodeRadius,
                width: nodeRadius * 2,
                height: nodeRadius * 2
            )

            let fill: Color
            if isHovered {
                fill = .accentColor
            } else if isNeighbor {
                fill = Color.accentColor.opacity(0.65)
            } else {
                fill = Color.secondary.opacity(0.42)
            }

            context.fill(Path(ellipseIn: rect), with: .color(fill))

            if isHovered {
                context.stroke(
                    Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)),
                    with: .color(Color.accentColor.opacity(0.3)),
                    lineWidth: 2
                )
                drawTitle(for: node, at: point, dotRadius: nodeRadius, size: size, context: &context)
            }
        }
    }

    private func drawTitle(
        for node: GraphNode,
        at point: CGPoint,
        dotRadius: CGFloat,
        size: CGSize,
        context: inout GraphicsContext
    ) {
        let label = node.folder.isEmpty ? node.title : "\(node.title) · \(node.folder)"
        let resolved = context.resolve(
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
        )
        let measured = resolved.measure(in: CGSize(width: 240, height: 40))

        var x = point.x - measured.width / 2
        x = min(max(x, 8), max(8, size.width - measured.width - 8))
        var y = point.y - dotRadius - measured.height - 12
        if y < 8 {
            y = point.y + dotRadius + 12
        }

        let background = CGRect(
            x: x - 7,
            y: y - 4,
            width: measured.width + 14,
            height: measured.height + 8
        )
        context.fill(
            Path(roundedRect: background, cornerRadius: 5),
            with: .color(Color(nsColor: .controlBackgroundColor))
        )
        context.stroke(
            Path(roundedRect: background, cornerRadius: 5),
            with: .color(Color.secondary.opacity(0.25)),
            lineWidth: 1
        )
        context.draw(resolved, at: CGPoint(x: x, y: y), anchor: .topLeading)
    }

    // MARK: - Hit testing

    private func updateHover(
        at location: CGPoint,
        data: KnowledgeGraphData,
        size: CGSize,
        radius: CGFloat
    ) {
        setHovered(node(at: location, data: data, size: size, radius: radius)?.id, data: data)
    }

    private func setHovered(_ id: URL?, data: KnowledgeGraphData) {
        guard hoveredID != id else { return }
        hoveredID = id

        guard let id else {
            neighborIDs = []
            return
        }
        neighborIDs = Set(data.edges.compactMap { edge in
            if edge.source == id { return edge.target }
            if edge.target == id { return edge.source }
            return nil
        })
    }

    private func node(
        at location: CGPoint,
        data: KnowledgeGraphData,
        size: CGSize,
        radius: CGFloat
    ) -> GraphNode? {
        let center = CGPoint(
            x: size.width / 2 + pan.width,
            y: size.height / 2 + pan.height
        )
        let threshold = max(12, min(max(4.5 * sqrt(zoom), 4), 9) + 8)

        var best: GraphNode?
        var bestDistance = threshold

        for node in data.nodes {
            let point = CGPoint(
                x: center.x + CGFloat(node.x) * radius,
                y: center.y + CGFloat(node.y) * radius
            )
            let distance = hypot(point.x - location.x, point.y - location.y)
            if distance < bestDistance {
                best = node
                bestDistance = distance
            }
        }
        return best
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let base = dragStart ?? committedPan
                if dragStart == nil {
                    dragStart = base
                }
                pan = CGSize(
                    width: base.width + value.translation.width,
                    height: base.height + value.translation.height
                )
            }
            .onEnded { _ in
                dragStart = nil
                committedPan = pan
            }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = min(max(committedZoom * value, 0.35), 4)
            }
            .onEnded { _ in
                committedZoom = zoom
            }
    }

    private func changeZoom(by factor: CGFloat) {
        zoom = min(max(zoom * factor, 0.35), 4)
        committedZoom = zoom
    }

    private func resetView() {
        zoom = 1
        committedZoom = 1
        pan = .zero
        committedPan = .zero
        hoveredID = nil
        neighborIDs = []
    }

    // MARK: - Chrome

    private func header(_ data: KnowledgeGraphData) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text("Graphe")
                .font(.system(size: 13, weight: .semibold))

            Text("\(data.nodes.count) notes · \(data.edges.count) liens")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .padding(12)
    }

    private var controls: some View {
        HStack(spacing: 2) {
            Button {
                changeZoom(by: 1.2)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoomer")

            Button {
                changeZoom(by: 1 / 1.2)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Dézoomer")

            Button {
                resetView()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .help("Recentrer le graphe")

            Divider()
                .frame(height: 14)
                .padding(.horizontal, 3)

            Button {
                store.dismissGraph()
            } label: {
                Image(systemName: "xmark")
            }
            .help("Fermer le graphe (⌘G)")
        }
        .font(.system(size: 12))
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .padding(12)
    }

    private var hint: some View {
        Text("Pincez pour zoomer · Glissez pour déplacer · Cliquez sur une note pour l'ouvrir")
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 12)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Construction du graphe…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Aucune note à afficher")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Ajoutez des notes contenant des liens [[comme ceci]] pour voir le graphe se construire.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(32)
    }
}
