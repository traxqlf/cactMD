import Foundation

/// One note skeleton offered by “Nouveau depuis un modèle…”.
///
/// Templates either come from a `_templates/` folder at the vault root or from
/// the three built-ins below, so a vault with no template folder still offers a
/// useful starting point.
nonisolated struct NoteTemplate: Identifiable, Hashable, Sendable {
    enum Origin: String, Hashable, Sendable {
        case vault
        case builtIn
    }

    let id: String
    let name: String
    let body: String
    let origin: Origin
}

nonisolated enum NoteTemplates {
    /// Folder read at the vault root, like Obsidian's own templates folder.
    static let folderName = "_templates"

    /// Vault templates when the folder exists and holds Markdown files, the
    /// built-ins otherwise.
    static func available(in root: URL?) -> [NoteTemplate] {
        if let root {
            let templates = vaultTemplates(in: root)
            if !templates.isEmpty { return templates }
        }
        return builtIns
    }

    private static func vaultTemplates(in root: URL) -> [NoteTemplate] {
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard let contents else { return [] }

        return contents
            .filter { FileTreeIndexer.isMarkdownFile($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url in
                guard let body = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return NoteTemplate(
                    id: url.path,
                    name: url.deletingPathExtension().lastPathComponent,
                    body: body,
                    origin: .vault
                )
            }
    }

    // MARK: - Variables

    /// Replaces `{{date}}`, `{{datetime}}` and `{{titre}}` once, at creation
    /// time: the note on disk never keeps a variable it was created with.
    static func render(_ body: String, title: String, date: Date = Date()) -> String {
        body
            .replacingOccurrences(of: "{{titre}}", with: title)
            .replacingOccurrences(of: "{{date}}", with: dayFormatter.string(from: date))
            .replacingOccurrences(of: "{{datetime}}", with: dateTimeFormatter.string(from: date))
    }

    /// A file name the template suggests for `{{titre}}`, stripped of the
    /// characters a note title cannot keep.
    static func suggestedTitle(for template: NoteTemplate) -> String {
        let name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Sans titre" : name
    }

    private static let dayFormatter: DateFormatter = makeFormatter("yyyy-MM-dd")
    private static let dateTimeFormatter: DateFormatter = makeFormatter("yyyy-MM-dd HH:mm")

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    // MARK: - Built-ins

    static let builtIns: [NoteTemplate] = [
        NoteTemplate(
            id: "builtin.revision",
            name: "Fiche de révision",
            body: """
            # {{titre}}

            **Date :** {{date}}

            ## Notions clés

            -

            ## Définitions

            | Terme | Définition |
            | --- | --- |
            |  |  |

            ## Questions à se poser

            - [ ]

            ## À revoir

            - [ ]
            """,
            origin: .builtIn
        ),
        NoteTemplate(
            id: "builtin.tp",
            name: "Compte-rendu TP",
            body: """
            # {{titre}}

            **Date :** {{date}}
            **Binôme :**

            ## Objectif

            ## Matériel et protocole

            1.

            ## Résultats

            ## Analyse

            ## Conclusion

            - [ ] Compte-rendu relu
            """,
            origin: .builtIn
        ),
        NoteTemplate(
            id: "builtin.procedure",
            name: "Procédure technique",
            body: """
            # {{titre}}

            _Dernière mise à jour : {{datetime}}_

            ## Contexte

            ## Prérequis

            ## Étapes

            1.

            ## Vérification

            - [ ]

            ## Dépannage

            ## Historique

            | Date | Auteur | Changement |
            | --- | --- | --- |
            | {{date}} |  | Création |
            """,
            origin: .builtIn
        )
    ]
}
