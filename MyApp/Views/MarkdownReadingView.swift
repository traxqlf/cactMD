import AppKit
import SwiftUI

/// Reading page built from native SwiftUI blocks.
///
/// TextKit's `NSTextTable` is workable for simple grids but fragile for
/// Markdown: cells must be exactly one paragraph, borders and padding are
/// harder to control, and code inside a table cell is easy to collapse. This
/// view uses the same block model as the parser, with a real SwiftUI `Grid`
/// for tables and a code card that scrolls horizontally, like GitHub/Obsidian.
struct MarkdownReadingView: View {
    let store: WorkspaceStore
    let note: LoadedNote
    let backlinks: [NoteReference]

    private let topLevelIDs: [Int: Int]

    @State private var topBlockID: Int?
    @State private var viewportWidth: CGFloat = 800
    @State private var isRestoringScroll = false
    @State private var didRestoreScroll = false

    init(store: WorkspaceStore, note: LoadedNote, backlinks: [NoteReference]) {
        self.store = store
        self.note = note
        self.backlinks = backlinks
        self.topLevelIDs = Self.makeTopLevelMap(note.blocks)
    }

    private var contentWidth: CGFloat {
        min(750, max(320, viewportWidth - 72))
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !note.frontmatter.isEmpty {
                    MarkdownFrontmatterView(fields: note.frontmatter)
                        .padding(.bottom, 18)
                }

                // Keep each top-level block as a direct child of the lazy
                // stack, so long notes really are lazy and every block can be
                // a scroll target.
                ForEach(note.blocks) { block in
                    MarkdownBlockView(
                        block: block,
                        store: store,
                        contentWidth: contentWidth,
                        muted: false
                    )
                    .id(block.id)
                }

                if !backlinks.isEmpty {
                    MarkdownBacklinksView(backlinks: backlinks, store: store)
                        .padding(.top, 28)
                }
            }
            .scrollTargetLayout()
            .frame(maxWidth: 750, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollPosition(id: $topBlockID, anchor: .top)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in
                        viewportWidth = width
                    }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            handleLink(url)
        })
        .onAppear(perform: restoreScrollIfNeeded)
        .onChange(of: store.pendingScrollBlockID) { _, blockID in
            guard let blockID else { return }
            scroll(to: blockID, clearPending: true)
        }
        .onChange(of: topBlockID) { _, blockID in
            guard !isRestoringScroll, let blockID else { return }
            let topLevel = topLevelIDs[blockID] ?? blockID
            if store.activeScrollBlockID != topLevel {
                store.activeScrollBlockID = topLevel
            }
        }
        .onDisappear {
            if let topBlockID {
                store.activeScrollBlockID = topLevelIDs[topBlockID] ?? topBlockID
            }
        }
    }

    // MARK: - Scroll position

    private func restoreScrollIfNeeded() {
        guard !didRestoreScroll else { return }
        didRestoreScroll = true
        if let pending = store.pendingScrollBlockID {
            scroll(to: pending, clearPending: true)
        } else if let active = store.activeScrollBlockID {
            scroll(to: active, clearPending: false)
        }
    }

    private func scroll(to blockID: Int, clearPending: Bool) {
        let target = topLevelIDs[blockID] ?? blockID
        guard topLevelIDs[target] != nil || note.blocks.contains(where: { $0.id == target }) else {
            return
        }

        isRestoringScroll = true
        withTransaction(Transaction(animation: nil)) {
            topBlockID = target
        }
        Task { @MainActor in
            await Task.yield()
            if clearPending, store.pendingScrollBlockID == blockID {
                store.pendingScrollBlockID = nil
            }
            isRestoringScroll = false
        }
    }

    private static func makeTopLevelMap(_ blocks: [MarkdownBlock]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        func visit(_ block: MarkdownBlock, topLevel: Int) {
            map[block.id] = topLevel
            switch block.kind {
            case let .blockQuote(children):
                for child in children { visit(child, topLevel: topLevel) }
            case let .list(_, _, items):
                for item in items {
                    for child in item.blocks { visit(child, topLevel: topLevel) }
                }
            default:
                break
            }
        }
        for block in blocks {
            visit(block, topLevel: block.id)
        }
        return map
    }

    // MARK: - Links

    private func handleLink(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == "systemmd" else {
            NSWorkspace.shared.open(url)
            return .handled
        }

        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "name" || $0.name == "path" || $0.name == "line" })?
            .value

        switch url.host {
        case "wikilink":
            if let value { store.requestWikilinkOpen(value) }
        case "tag":
            if let value { store.applyTagFilter(value) }
        case "checkbox":
            if let value, let line = Int(value) {
                store.toggleTaskCheckbox(atLine: line)
            }
        case "image":
            if let value { ImageQuickLook.shared.present(URL(fileURLWithPath: value)) }
        case "note":
            if let value { store.openNote(at: URL(fileURLWithPath: value)) }
        default:
            break
        }
        return .handled
    }
}

// MARK: - Blocks

private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    let store: WorkspaceStore
    let contentWidth: CGFloat
    let muted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                MarkdownBlockView(
                    block: block,
                    store: store,
                    contentWidth: contentWidth,
                    muted: muted
                )
                .id(block.id)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let store: WorkspaceStore
    let contentWidth: CGFloat
    let muted: Bool

    private var textColor: Color {
        muted ? .secondary : .primary
    }

    var body: some View {
        switch block.kind {
        case let .heading(level, text):
            MarkdownInlineTextView(lazy: text, color: textColor)
                .lineSpacing(3)
                .padding(.top, level == 1 ? 20 : 12)
                .padding(.bottom, level == 1 ? 10 : 6)

        case let .paragraph(text):
            MarkdownInlineTextView(lazy: text, color: textColor)
                .lineSpacing(5)
                .padding(.bottom, 14)

        case let .codeBlock(language, code, highlighted):
            MarkdownCodeBlockView(
                language: language,
                code: code,
                highlighted: highlighted
            )
            .frame(maxWidth: contentWidth, alignment: .leading)
            .padding(.top, 14)
            .padding(.bottom, 16)

        case let .blockQuote(children):
            MarkdownBlocksView(
                blocks: children,
                store: store,
                contentWidth: contentWidth - 15,
                muted: true
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 15)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 3)
            }
            .padding(.bottom, 14)

        case let .list(ordered, startIndex, items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                    HStack(alignment: .top, spacing: 8) {
                        MarkdownListMarkerView(
                            ordered: ordered,
                            index: startIndex + offset,
                            item: item,
                            store: store
                        )
                        .padding(.top, 1)

                        MarkdownBlocksView(
                            blocks: item.blocks,
                            store: store,
                            contentWidth: contentWidth - 30,
                            muted: muted
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.bottom, 12)

        case let .table(alignments, headers, rows):
            MarkdownTableView(
                alignments: alignments,
                headers: headers,
                rows: rows,
                contentWidth: contentWidth
            )
            .padding(.top, 14)
            .padding(.bottom, 18)

        case let .image(url, alt):
            MarkdownImageView(url: url, alt: alt, contentWidth: contentWidth)
                .padding(.bottom, 14)

        case .thematicBreak:
            Divider()
                .padding(.vertical, 14)
        }
    }
}

private struct MarkdownListMarkerView: View {
    let ordered: Bool
    let index: Int
    let item: MarkdownListItem
    let store: WorkspaceStore

    var body: some View {
        if let checked = item.checkbox {
            Button {
                if let line = item.sourceLine {
                    store.toggleTaskCheckbox(atLine: line)
                }
            } label: {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(checked ? "Marquer comme non terminé" : "Marquer comme terminé")
        } else if ordered {
            Text("\(index).")
                .font(.system(size: 13.5, weight: .regular).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 20, alignment: .trailing)
        } else {
            Text("•")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 12, alignment: .center)
        }
    }
}

private struct MarkdownInlineTextView: View {
    let lazy: LazyAttributed
    var color: Color = .primary
    var alignment: TextAlignment = .leading

    var body: some View {
        Text(MarkdownTextStyler.swiftUIAttributed(lazy, baseColor: color))
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

// MARK: - Code

private struct MarkdownCodeBlockView: View {
    let language: String?
    let code: String
    let highlighted: LazyAttributed

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let language, !language.isEmpty {
                    Text(language.lowercased())
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copier le code")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 5)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(MarkdownTextStyler.swiftUIAttributed(highlighted))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

// MARK: - Table

private struct MarkdownTableView: View {
    let alignments: [MarkdownTableAlignment]
    let headers: [LazyAttributed]
    let rows: [[LazyAttributed]]
    let contentWidth: CGFloat

    private var columnCount: Int {
        max(headers.count, rows.map(\.count).max() ?? 0)
    }

    private var columnWidth: CGFloat {
        max(120, contentWidth / CGFloat(max(1, columnCount)))
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { column in
                        cell(
                            column < headers.count ? headers[column] : nil,
                            column: column,
                            isHeader: true
                        )
                    }
                }

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { column in
                            cell(
                                column < row.count ? row[column] : nil,
                                column: column,
                                isHeader: false
                            )
                        }
                    }
                }
            }
            .frame(minWidth: contentWidth, alignment: .leading)
            .overlay(
                Rectangle()
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell(
        _ lazy: LazyAttributed?,
        column: Int,
        isHeader: Bool
    ) -> some View {
        let alignment: TextAlignment = switch column < alignments.count ? alignments[column] : .left {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }

        return Group {
            if let lazy {
                MarkdownInlineTextView(
                    lazy: lazy,
                    color: .primary,
                    alignment: alignment
                )
            } else {
                Text("")
            }
        }
        .lineSpacing(2)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: columnWidth, alignment: frameAlignment(alignment))
        .background(isHeader ? Color.primary.opacity(0.06) : Color.clear)
        // One line per shared edge: top + leading here, outer border on the
        // grid. Avoids the double 1 pt strokes of per-cell strokeBorder.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
    }

    private func frameAlignment(_ alignment: TextAlignment) -> Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

// MARK: - Images and page furniture

private struct MarkdownImageView: View {
    let url: URL
    let alt: String
    let contentWidth: CGFloat

    var body: some View {
        if let image = MediaLibrary.thumbnail(at: url, maxPixelSize: 1600) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: contentWidth, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onTapGesture {
                    ImageQuickLook.shared.present(url)
                }
                .help(alt)
        } else {
            Label(alt.isEmpty ? url.lastPathComponent : alt, systemImage: "photo")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
    }
}

private struct MarkdownFrontmatterView: View {
    let fields: [FrontmatterField]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Propriétés")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(fields) { field in
                HStack(alignment: .top, spacing: 12) {
                    Text(field.key)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .leading)

                    Text(field.value.isEmpty ? "—" : field.value)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct MarkdownBacklinksView: View {
    let backlinks: [NoteReference]
    let store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rétro-liens (\(backlinks.count))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            ForEach(backlinks) { reference in
                Button {
                    store.openNote(at: reference.url)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Text(reference.name)
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(reference.folder)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
