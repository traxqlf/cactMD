import SwiftUI

/// “Nouveau depuis un modèle…” panel: pick a skeleton, name the note, create it.
///
/// The title field is optional: leaving it empty names the note after the
/// template, which is exactly what `{{titre}}` expands to inside the body.
struct TemplatePickerView: View {
    let store: WorkspaceStore

    @State private var title = ""
    @State private var selection = 0

    private var templates: [NoteTemplate] { store.templateOptions }

    private var currentTemplate: NoteTemplate? {
        guard !templates.isEmpty else { return nil }
        return templates[min(max(selection, 0), templates.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if templates.isEmpty {
                Text("Aucun modèle disponible.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
            } else {
                Divider()
                templateList
            }

            Divider()
            hintsBar
        }
        .frame(width: 480)
        .floatingGlassPanel()
        .onExitCommand {
            store.dismissTemplatePicker()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)

            PaletteSearchField(
                text: $title,
                placeholder: currentTemplate.map {
                    "Titre de la note (\(NoteTemplates.suggestedTitle(for: $0)))"
                } ?? "Titre de la note",
                fontSize: 16,
                onQueryChange: { _ in },
                onMove: { delta in
                    guard !templates.isEmpty else { return }
                    selection = min(max(selection + delta, 0), templates.count - 1)
                },
                onSubmit: { createCurrent() },
                onCancel: { store.dismissTemplatePicker() }
            )
            .frame(height: 26)

            Text("esc")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var templateList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(templates.enumerated()), id: \.element.id) { index, template in
                        row(template: template, index: index)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 300)
            .onChange(of: selection) { _, newValue in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func row(template: NoteTemplate, index: Int) -> some View {
        Button {
            selection = index
            createCurrent()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: template.origin == .vault ? "folder" : "square.stack.3d.up")
                    .font(.system(size: 13))
                    .foregroundStyle(index == selection ? Color.accentColor : Color.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(template.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                    Text(template.origin == .vault ? "Modèle du dossier \(NoteTemplates.folderName)" : "Modèle intégré")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if index == selection {
                    Image(systemName: "return")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(index == selection ? Color.accentColor.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(index)
    }

    private var hintsBar: some View {
        HStack(spacing: 14) {
            hint("↑↓", "Choisir")
            hint("⏎", "Créer")
            hint("esc", "Fermer")
            Spacer()
            Text("{{date}} · {{datetime}} · {{titre}}")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    private func createCurrent() {
        guard let template = currentTemplate else { return }
        let name = title
        store.dismissTemplatePicker()
        store.createNote(from: template, titled: name)
    }
}
