import AppKit
import SwiftUI

struct MarkdownReaderView: View {
    let store: WorkspaceStore
    @State private var webController = MarkdownWebViewController()
    @State private var pageWidth: CGFloat = 0

    /// Mirrors the page CSS: 700 pt while the Finder is open, then the freed
    /// width up to 960 pt, so the header text lines up with the note body.
    private var contentMaxWidth: CGFloat {
        guard !store.isSidebarVisible else { return 700 }
        return min(960, max(700, pageWidth - 360))
    }

    /// Mirrors `padding: 36px clamp(24px, 5vw, 48px) 80px` in the renderer:
    /// 5 vw is 5 % of the viewport, which here is the whole page.
    private var contentHorizontalInset: CGFloat {
        min(48, max(24, pageWidth * 0.05))
    }

    var body: some View {
        Group {
            if store.rootURL == nil {
                emptyRootState
            } else if store.isEditing {
                MarkdownEditorView(store: store)
                    .id(store.activeTabID)
            } else {
                let note = store.loadedNote ?? Self.placeholderNote
                ZStack {
                    notePage(note)
                        .opacity(store.loadedNote == nil ? 0 : 1)

                    if store.loadedNote == nil {
                        if store.isNoteLoading {
                            openingNoteState
                        } else {
                            emptySelectionState
                        }
                    }

                    if store.isSwitchingNote {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.top, 8)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .onChange(of: store.pendingScrollBlockID) { _, blockID in
            guard let blockID else { return }
            webController.scrollToHeading(blockID)
            store.pendingScrollBlockID = nil
        }
    }

    private static let placeholderNote = LoadedNote(
        url: URL(fileURLWithPath: "/"),
        modificationDate: nil,
        byteCount: 0,
        blocks: [],
        headings: [],
        frontmatter: [],
        tags: [],
        wordCount: 0,
        characterCount: 0
    )

    private func notePage(_ note: LoadedNote) -> some View {
        VStack(spacing: 0) {
            // Le titre de note, les propriétés, le corps et les rétro-liens sont
            // rendus dans le WebKit (style Obsidian). On conserve l'en-tête léger
            // (date/taille/tags) et la barre d'état de l'app.
            noteHeader(note)
                .padding(.horizontal, contentHorizontalInset)
                .frame(maxWidth: contentMaxWidth, alignment: .leading)
                .padding(.top, 10)
                .padding(.bottom, 0)
                .frame(maxWidth: .infinity, alignment: .center)

            MarkdownWebView(
                controller: webController,
                store: store,
                note: note,
                backlinks: store.backlinks
            )

            ReaderStatusBar(note: note)
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PageWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(PageWidthKey.self) { pageWidth = $0 }
    }

    private func noteHeader(_ note: LoadedNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let date = note.modificationDate {
                    Text(date, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text(ByteCountFormatter.string(fromByteCount: Int64(note.byteCount), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()
            }

            if !note.tags.isEmpty {
                tagStrip(note.tags)
            }
        }
    }

    private func tagStrip(_ tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags.prefix(12), id: \.self) { tag in
                    Button {
                        store.applyTagFilter(tag)
                    } label: {
                        Text("#\(tag)")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Filtrer les notes avec #\(tag)")
                }

                if tags.count > 12 {
                    Text("+\(tags.count - 12)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Shown while a note is being read from disk. Large or remote (iCloud)
    /// files can take a moment; an empty page there looked like a dead app.
    private var openingNoteState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Ouverture de « \(store.openNoteURL?.deletingPathExtension().lastPathComponent ?? "la note") »…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyRootState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 76, height: 76)
                Image(systemName: "doc.richtext")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 6) {
                Text("cactMD")
                    .font(.system(size: 24, weight: .semibold))
                Text("Vos notes Markdown, entièrement hors ligne.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button("Ouvrir un dossier…") {
                store.chooseFolder()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 2)

            ShortcutHintList(items: [
                (keys: "⌘⇧O", label: "Ouvrir un dossier"),
                (keys: "⌘G", label: "Graphe des notes"),
                (keys: "⌘⇧F", label: "Recherche plein texte")
            ])
            .padding(.top, 6)
        }
        .padding(32)
    }

    private var emptySelectionState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)

            Text("Aucune note sélectionnée")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            Text("Choisissez un fichier Markdown dans l'explorateur ou créez une nouvelle note.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            ShortcutHintList(items: [
                (keys: "⌘O", label: "Recherche rapide"),
                (keys: "⌘T", label: "Nouvel onglet"),
                (keys: "⌘⇧F", label: "Recherche plein texte")
            ])
            .padding(.top, 6)

            if !store.recentNotes.isEmpty {
                recentNotesSection
                    .padding(.top, 2)
            }
        }
        .padding(32)
    }

    /// Discreet shortcut to the four most recent notes when nothing is open.
    private var recentNotesSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Récents")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)

            ForEach(store.recentNotes.prefix(4)) { note in
                Button {
                    store.openNote(at: note.url)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Text(note.name)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(note.relativeDayLabel)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 280)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PageWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ShortcutHintList: View {
    let items: [(keys: String, label: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 10) {
                    Text(item.keys)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .frame(minWidth: 52)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )

                    Text(item.label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
        .frame(width: 280)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
