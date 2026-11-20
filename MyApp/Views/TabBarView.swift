import SwiftUI

/// Floating pill-shaped tab strip sitting on the reading surface, followed by
/// the discrete note actions (history, read/edit, outline, graph, search).
struct TabBarView: View {
    @Bindable var store: WorkspaceStore

    @State private var showingOutline = false
    @State private var showingAI = false
    /// Width of the tab pills only, so the "+" can hug the last one instead of
    /// being pushed to the end of a fixed 620 pt strip.
    @State private var tabsWidth: CGFloat = 620

    var body: some View {
        HStack(spacing: 8) {
            if !store.isSidebarVisible {
                GlassIconButton(systemName: "sidebar.left", help: "Afficher ou masquer le Finder (⌘\\)") {
                    withAnimation(.snappy(duration: 0.22)) {
                        store.toggleSidebar()
                    }
                }
            }

            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.tabs) { tab in
                            TabItemView(store: store, tab: tab)
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 2)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: TabStripWidthKey.self, value: proxy.size.width)
                        }
                    )
                }
                .frame(width: min(tabsWidth, 620), alignment: .leading)
                .onPreferenceChange(TabStripWidthKey.self) { tabsWidth = $0 }

                // Follows the last tab; only scrolls once the strip is capped.
                GlassIconButton(systemName: "plus", help: "Nouvel onglet (⌘T)") {
                    store.newTab()
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                GlassIconButton(
                    systemName: "chevron.left",
                    help: "Précédent (⌘[)",
                    isEnabled: store.canGoBack
                ) {
                    store.goBack()
                }

                GlassIconButton(
                    systemName: "chevron.right",
                    help: "Suivant (⌘])",
                    isEnabled: store.canGoForward
                ) {
                    store.goForward()
                }

                // A PDF has no Markdown source to edit: the pencil stays out of
                // reach instead of opening an empty editor.
                GlassIconButton(
                    systemName: store.isEditing ? "eye" : "pencil",
                    help: store.isEditing ? "Mode lecture (⌘⇧E)" : "Mode édition (⌘⇧E)",
                    isActive: store.isEditing,
                    isEnabled: !store.isGraphPresented
                        && !store.isPDFDocumentOpen
                        && store.openNoteURL != nil
                ) {
                    store.toggleEditMode()
                }

                // Typewriter mode lives next to read/edit: it changes how the
                // editor looks while the note is being written.
                GlassIconButton(
                    systemName: "character.cursor.ibeam",
                    help: "Mode Focus, machine à écrire (⌘⌥T)",
                    isActive: store.isFocusMode,
                    isEnabled: !store.isGraphPresented
                        && !store.isPDFDocumentOpen
                        && store.openNoteURL != nil
                ) {
                    store.toggleFocusMode()
                }

                GlassIconButton(
                    systemName: "sparkles",
                    help: "Assistant de la note (Apple Intelligence, hors ligne)",
                    isActive: showingAI,
                    isEnabled: store.openNoteURL != nil
                        && !store.isGraphPresented
                        && !store.isPDFDocumentOpen
                ) {
                    showingAI = true
                }
                .popover(isPresented: $showingAI, arrowEdge: .bottom) {
                    NoteAIPopoverView(store: store)
                }

                outlineButton

                GlassIconButton(
                    systemName: "point.3.connected.trianglepath.dotted",
                    help: "Graphe des notes (⌘G)",
                    isActive: store.isGraphPresented,
                    isEnabled: !store.isPDFDocumentOpen
                ) {
                    store.toggleGraphPresentation()
                }

                GlassIconButton(
                    systemName: "text.magnifyingglass",
                    help: "Rechercher dans les notes (⌘⇧F)"
                ) {
                    store.presentSearch()
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        // The top inset and the 34 pt row height live in ContentView, which owns
        // the window-top layout (8 pt from the edge, sheet 8 pt below).
        .onChange(of: store.openNoteURL) { _, _ in
            showingAI = false
        }
        // A contextual action picked in the editor opens the assistant here.
        .onChange(of: store.aiAssistantOpenRequests) { _, _ in
            showingAI = true
        }
        .onChange(of: store.isGraphPresented) { _, presented in
            if presented { showingAI = false }
        }
    }

    private var outlineButton: some View {
        GlassIconButton(
            systemName: "list.bullet.indent",
            help: "Plan de la note",
            isEnabled: !store.isGraphPresented
                && !store.isPDFDocumentOpen
                && !(store.loadedNote?.headings.isEmpty ?? true)
        ) {
            showingOutline = true
        }
        .popover(isPresented: $showingOutline, arrowEdge: .bottom) {
            OutlinePopoverView(
                headings: store.loadedNote?.headings ?? [],
                activeHeadingID: store.activeHeadingID
            ) { blockID in
                showingOutline = false
                store.scrollToBlock(blockID)
            }
        }
    }
}

private struct TabStripWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TabItemView: View {
    @Bindable var store: WorkspaceStore
    let tab: WorkspaceTab

    @State private var isHovering = false

    private var isActive: Bool { tab.id == store.activeTabID }

    private var tabIconName: String {
        if store.isTabEditing(tab) { return "pencil" }
        if store.tabURL(tab).map(FileTreeIndexer.isPDFFile) == true { return "doc.richtext" }
        return "doc.text"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tabIconName)
                .font(.system(size: 10.5))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)

            Text(store.tabTitle(tab))
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)

            if isHovering {
                Button {
                    store.closeTab(id: tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Fermer l'onglet (⌘W)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minWidth: 92, maxWidth: 190)
        .background(
            GlassPillBackground(cornerRadius: 11, isActive: isActive, isHovering: isHovering)
        )
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture {
            store.activateTab(id: tab.id)
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .overlay(
            MiddleClickCatcher { store.closeTab(id: tab.id) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        .help(store.tabURL(tab)?.path ?? "Nouvel onglet")
        .accessibilityLabel(store.tabTitle(tab))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
