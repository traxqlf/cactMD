import AppKit
import SwiftUI

/// Native popover for the on-device note assistant. It owns one
/// `NoteAIService`: closing the popover cancels the stream and releases the
/// FoundationModels session.
struct NoteAIPopoverView: View {
    @Bindable var store: WorkspaceStore
    @State private var ai = NoteAIService()
    @State private var question = ""
    @State private var confirmation: String?
    @State private var selectionText = ""
    @FocusState private var isQuestionFocused: Bool

    private var noteName: String {
        store.openNoteURL?.deletingPathExtension().lastPathComponent ?? "Aucune note ouverte"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.35)

            if ai.availability.isAvailable {
                VStack(alignment: .leading, spacing: 12) {
                    selectionSection
                    quickActions
                    questionField
                    resultSection
                    footer
                }
                .padding(14)
            } else {
                unavailableState
            }
        }
        .frame(width: 380)
        .background(.regularMaterial)
        .onAppear {
            ai.refreshAvailability()
            if ai.availability.isAvailable { ai.prewarm() }
            #if DEBUG
            NoteAIDocumentEditor.selfCheck()
            #endif
            consumePendingSelection()
        }
        .onDisappear {
            ai.cancel()
            selectionText = ""
            store.pendingAISelection = nil
        }
        .onChange(of: store.pendingAISelection?.id) { _, _ in
            consumePendingSelection()
        }
        .onChange(of: store.openNoteURL) { _, _ in
            ai.cancel()
            confirmation = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.accentColor, Color.purple.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("Assistant de la note")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(noteName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if ai.isRunning {
                Button {
                    ai.cancel()
                } label: {
                    Label("Arrêter", systemImage: "stop.fill")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Arrêter la génération")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Contextual selection

    /// What the ✨ actions will work on: the passage that opened the popover,
    /// or whatever is highlighted in the editor right now.
    private var activeSelection: String? {
        if !selectionText.isEmpty { return selectionText }
        if !store.editorSelectionPreview.isEmpty { return store.editorSelectionPreview }
        return nil
    }

    @ViewBuilder
    private var selectionSection: some View {
        if let selection = activeSelection {
            VStack(alignment: .leading, spacing: 7) {
                Label("Sélection", systemImage: "text.quote")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(selection)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    ForEach(NoteAISelectionAction.allCases, id: \.self) { action in
                        Button {
                            runSelection(action)
                        } label: {
                            Label(action.buttonTitle, systemImage: action.buttonIcon)
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(ai.isRunning || selection.isEmpty)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.07))
            )
        }
    }

    private func runSelection(_ action: NoteAISelectionAction) {
        guard let text = activeSelection, !text.isEmpty else { return }
        selectionText = text
        confirmation = nil
        isQuestionFocused = false
        ai.runSelection(action, text: text)
    }

    /// Picks up the request posted by the editor's right-click menu.
    private func consumePendingSelection() {
        guard let request = store.consumePendingAISelection() else { return }
        selectionText = request.text
        confirmation = nil
        ai.runSelection(request.action, text: request.text)
    }

    // MARK: - Actions

    private var quickActions: some View {
        HStack(spacing: 6) {
            actionButton("Résumer la note", icon: "list.bullet.rectangle", action: .summary)
            actionButton("Propriétés & tags", icon: "tag", action: .metadata)
            actionButton("Corriger le texte", icon: "checkmark.seal", action: .proofread)
        }
    }

    private func actionButton(_ title: String, icon: String, action: NoteAIAction) -> some View {
        let isSelected = ai.action == action

        return Button {
            begin(action)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.82))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.055))
            )
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(isSelected ? 0.42 : 0.26),
                            .white.opacity(0.06)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(ai.isRunning || store.openNoteURL == nil)
        .opacity(ai.isRunning && !isSelected ? 0.55 : 1)
        .help(title)
    }

    private var questionField: some View {
        HStack(spacing: 7) {
            Image(systemName: "questionmark.bubble")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Poser une question sur cette note…", text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isQuestionFocused)
                .onSubmit(sendQuestion)
                .disabled(store.openNoteURL == nil)

            if !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: sendQuestion) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Envoyer (↩)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.primary.opacity(0.055)))
        .overlay(
            Capsule().strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.30), .white.opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.75
            )
        )
    }

    // MARK: - Result

    @ViewBuilder
    private var resultSection: some View {
        if ai.isRunning && ai.output.isEmpty {
            progressRow
        } else if let metadata = ai.metadata {
            metadataPreview(metadata)
            resultActions
        } else if !ai.output.isEmpty {
            outputPreview
            resultActions
        }

        if ai.noteWasTruncated {
            Label(
                ai.action == .proofread
                    ? "Note trop longue : la correction complète est désactivée."
                    : "Seuls les 9 000 premiers caractères ont été analysés.",
                systemImage: "scissors"
            )
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }

        if let error = ai.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let confirmation {
            Label(confirmation, systemImage: "checkmark.circle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var progressRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(progressLabel)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(height: 42)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    private var progressLabel: String {
        if ai.isPreparing { return "Lecture de la note…" }
        switch ai.action {
        case .metadata: return "Extraction des propriétés…"
        case .proofread: return "Correction en cours…"
        case .summary: return "Rédaction du résumé…"
        case .ask: return "Recherche dans la note…"
        case .explainSelection: return "Explication du passage…"
        case .proofreadSelection: return "Correction de la sélection…"
        case .summarizeSelection: return "Résumé de la sélection…"
        case nil: return "Génération en cours…"
        }
    }

    private var outputPreview: some View {
        ScrollView {
            Text(ai.output + (ai.isRunning ? " ▍" : ""))
                .font(.system(size: 11.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(height: 168)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
        )
    }

    private func metadataPreview(_ metadata: NoteAIMetadata) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if !metadata.summary.isEmpty {
                Text(metadata.summary)
                    .font(.system(size: 11.5))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !metadata.category.isEmpty {
                HStack(spacing: 5) {
                    Text("Catégorie")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(metadata.category)
                        .font(.system(size: 10.5, weight: .medium))
                }
            }

            if !metadata.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(metadata.tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.10), in: Capsule())
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
        )
    }

    @ViewBuilder
    private var resultActions: some View {
        if ai.hasResult, !ai.isRunning {
            HStack(spacing: 8) {
                primaryAction

                Button {
                    copyResult()
                } label: {
                    Label("Copier", systemImage: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Copier le résultat")

                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch ai.action {
        case .summary:
            Button {
                insertSummary()
            } label: {
                Label("Insérer le résumé en haut", systemImage: "text.insert")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

        case .metadata:
            Button {
                applyMetadata()
            } label: {
                Label("Appliquer les propriétés YAML", systemImage: "square.and.arrow.down")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

        case .proofread:
            Button {
                replaceContent()
            } label: {
                Label("Remplacer le contenu", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!ai.canReplace)

        case .proofreadSelection:
            Button {
                replaceSelection()
            } label: {
                Label("Remplacer la sélection", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!ai.canReplace)

        case .summarizeSelection:
            Button {
                insertSelectionSummary()
            } label: {
                Label("Insérer sous la sélection", systemImage: "text.insert")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

        case .explainSelection:
            EmptyView()

        case .ask, .none:
            EmptyView()
        }
    }

    private func replaceSelection() {
        guard ai.canReplace else { return }
        store.replaceEditorSelection?(ai.output)
        confirmation = "Sélection corrigée. ⌘Z pour annuler."
    }

    private func insertSelectionSummary() {
        guard !ai.output.isEmpty else { return }
        store.insertBelowEditorSelection?(ai.output)
        confirmation = "Résumé inséré sous la sélection."
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.shield")
                .font(.system(size: 9))
            Text("100 % local · aucune connexion réseau")
                .font(.system(size: 9.5))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.tertiary)
    }

    // MARK: - Unavailable

    private var unavailableState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)

            Text(ai.availability.title)
                .font(.system(size: 13, weight: .semibold))

            Text(ai.availability.message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Vérifier à nouveau") {
                ai.refreshAvailability()
                if ai.availability.isAvailable { ai.prewarm() }
            }
            .controlSize(.small)

            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Commands

    private func begin(_ action: NoteAIAction) {
        guard let url = store.openNoteURL else { return }
        confirmation = nil
        isQuestionFocused = false
        ai.run(action, noteURL: url, editorText: store.isEditing ? store.editorText : nil)
    }

    private func sendQuestion() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        begin(.ask(trimmed))
        question = ""
    }

    private func currentSource() async -> String? {
        guard let url = store.openNoteURL else { return nil }
        return await NoteAIService.loadSource(
            for: url,
            editorText: store.isEditing ? store.editorText : nil
        )
    }

    private func insertSummary() {
        Task {
            guard let source = await currentSource() else { return }
            let updated = NoteAIDocumentEditor.insertingSummary(ai.output, into: source)
            confirmation = store.replaceOpenNoteContent(with: updated)
                ? "Résumé inséré en haut de la note."
                : "L'écriture de la note a échoué."
        }
    }

    private func applyMetadata() {
        Task {
            guard let metadata = ai.metadata, let source = await currentSource() else { return }
            let updated = NoteAIDocumentEditor.mergingMetadata(metadata, into: source)
            confirmation = store.replaceOpenNoteContent(with: updated)
                ? "Propriétés YAML appliquées."
                : "L'écriture de la note a échoué."
        }
    }

    private func replaceContent() {
        Task {
            guard ai.canReplace, let source = await currentSource() else { return }
            guard source.hashValue == ai.sourceFingerprint else {
                confirmation = "La note a changé depuis la correction. Relancez-la pour ne rien écraser."
                return
            }
            confirmation = store.replaceOpenNoteContent(with: ai.output)
                ? "Contenu remplacé."
                : "L'écriture de la note a échoué."
        }
    }

    private func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ai.copyText, forType: .string)
        confirmation = "Résultat copié."
    }
}
