# 🌵 cactMD (Tutorial in English below 🇬🇧)

Un éditeur et lecteur Markdown natif pour macOS, rapide et léger, écrit en **Swift** avec **SwiftUI**, **AppKit** (`NSOutlineView`, `NSTextView`) et une **`WKWebView`** pour le rendu de lecture. Pensé pour les cours et les notes techniques : ouvrez un dossier comme coffre, écrivez en Live Preview, naviguez par `[[wikilinks]]` et gardez le tout hors ligne.

---

## 📥 Téléchargement (Download)
Vous ne souhaitez pas compiler le code ? Téléchargez directement la dernière version :
* **[👉 Télécharger l'installeur macOS (.dmg)](https://github.com/traxqlf/cactMD/releases/latest)** — Apple Silicon, macOS 14+

**Installation :** ouvrez le `.dmg`, glissez **cactMD** dans le dossier **Applications**, puis lancez-le. Les mises à jour suivantes sont proposées automatiquement dans l'app (menu **cactMD › Rechercher des mises à jour…**, Sparkle 2).

## ⚠️ Note importante
cactMD n'est pas signé avec un certificat Developer ID ni notarisé par Apple. Au premier lancement, macOS peut afficher « cactMD ne peut pas être ouvert car Apple ne peut pas vérifier… » :
1. Ouvrez **Réglages Système › Confidentialité et sécurité**.
2. Descendez jusqu'au message concernant cactMD et cliquez sur **Ouvrir quand même**.
3. Confirmez avec **Ouvrir**.

*(Cette manipulation n'est à faire qu'au tout premier lancement, et se répète après chaque mise à jour.)*

---

## ✨ Fonctionnalités
* 📂 **Coffre de notes local** : ouvrez n'importe quel dossier de `.md`, explorateur façon Finder (arborescence ou mosaïque), onglets, notes récentes, renommage/déplacement/duplication, tags Finder natifs et indexation incrémentale par FSEvents.
* 🖊️ **Éditeur Live Preview** : les délimiteurs Markdown (`**`, `*`, `` ` ``, `#`, `>`, `[]()`, `[[ ]]`) s'effacent pendant la frappe tout en laissant le fichier `.md` strictement standard ; autosave atomique, `⌘Z` natif, collage/glisser-déposer d'images dans `assets/`, continuation automatique des listes et des cases à cocher.
* 🔗 **Wikilinks et backlinks** : `[[Note]]` ou `[[Note|Alias]]` cliquables, autocomplétion au `[[`, création de la note manquante proposée, backlinks calculés pour chaque note.
* 🕸️ **Graphe des notes** (`⌘G`) : visualisation des liens entre notes et des notes orphelines, ouverture d'un nœud d'un clic.
* 🔍 **Recherche** : palette de recherche rapide floue sur les titres et chemins (`⌘O`), recherche plein texte dans tout le coffre (`⌘⇧F`), filtre de l'explorateur.
* 🧩 **Modèles** (`⌘⇧N`) : *Fiche de révision*, *Compte-rendu TP* et *Procédure technique* intégrés, ou vos propres modèles dans `_templates/` à la racine du coffre (`{{date}}`, `{{datetime}}`, `{{titre}}`).
* ✅ **Tâches et plan** : cases `- [ ]` / `- [x]` cliquables en lecture comme en édition (la ligne exacte du fichier est mise à jour), plan des titres synchronisé avec la section visible.
* 📄 **PDF** : les PDF du dossier s'ouvrent dans un onglet (PDFKit, recherche `⌘F`, zoom) et l'export PDF du Markdown est **vectoriel** ; `⌘P` imprime la note ou la page PDF affichée.
* 🎯 **Mode Focus / machine à écrire** (`⌘⌥T`) : le paragraphe en cours reste centré, le reste s'atténue.
* 🤖 **IA locale** (macOS 26+, Apple Intelligence) : résumer, corriger ou expliquer la note ou la sélection, sans envoyer le texte à un serveur. Correction appliquée à la sélection avec l'Undo natif.
* 📥 **Capture système** : sélectionnez du texte dans n'importe quelle app, puis **Services › Capturer dans cactMD** : le texte est ajouté à `Inbox/Capture-AAAA-MM-JJ.md` et la note s'ouvre.
* 🍃 **Léger et hors ligne** : rendu Markdown, coloration syntaxique (Prism) et ressources embarquées dans l'app, aucune requête réseau pour lire ou écrire vos notes.

### ⌨️ Raccourcis essentiels
| Raccourci | Action |
| --- | --- |
| `⌘⇧E` | Basculer Lecture / Édition |
| `⌘O` | Recherche rapide (titres et chemins) |
| `⌘⇧F` | Recherche plein texte |
| `⌘N` / `⌘⇧N` / `⌘⌥N` | Nouvelle note / depuis un modèle / nouveau dossier |
| `⌘T`, `⌘W`, `⌘1…9` | Nouvel onglet, fermer l'onglet, onglet n° n |
| `⌘G` | Graphe des notes |
| `⌘⌥T` | Mode Focus |
| `⌘B` `⌘I` `⌘E` `⌘K` | Gras, italique, code inline, lien |
| `⌘P` | Imprimer / exporter en PDF |

## 🛠️ Prérequis (Pour les développeurs)
Pour compiler et exécuter ce projet depuis le code source :
* **macOS 14 (Sonoma) ou supérieur**, Apple Silicon.
* **Xcode 15 ou supérieur** (le projet se compile avec Xcode 27.2 / Swift 6.4 sans warning).
* Aucune dépendance externe à installer : **Sparkle** est résolu automatiquement par Swift Package Manager au premier build.
* *Facultatif :* **macOS 26** pour les fonctions Apple Intelligence (`FoundationModels`).

## 🚀 Installation & Utilisation (Via le code source)

1. **Cloner le dépôt sur votre machine :**
   ```bash
   git clone https://github.com/traxqlf/cactMD.git
   cd cactMD
   ```

2. **Ouvrir le projet dans Xcode et lancer :**
   ```bash
   open systemMD.xcodeproj
   ```
   Scheme `MyApp`, puis `⌘R`. Ou en ligne de commande :
   ```bash
   xcodebuild -scheme MyApp -destination 'platform=macOS' -derivedDataPath ./build build
   open ./build/Build/Products/Debug/cactMD.app
   ```

3. **Compiler la version Release :**
   ```bash
   xcodebuild -scheme MyApp -configuration Release -destination 'platform=macOS' -derivedDataPath ./build-release build
   ```

4. **Publier une version (zip + appcast Sparkle signé) :**
   ```bash
   ./scripts/release.sh 1.0.1
   ```
   Le script incrémente `CFBundleVersion`, met à jour `CFBundleShortVersionString`, produit l'installeur `dist/cactMD-1.0.1.dmg`, l'archive Sparkle `dist/cactMD-1.0.1.zip` et l'appcast signé `dist/appcast.xml`. Il reste à joindre ces trois fichiers à une release GitHub taguée `v1.0.1`.

<br>
<br>

# 🌵 cactMD (English 🇬🇧)

A fast, lightweight native Markdown editor and reader for macOS, written in **Swift** with **SwiftUI**, **AppKit** (`NSOutlineView`, `NSTextView`) and a **`WKWebView`** for reading. Built for coursework and technical notes: open any folder as a vault, write in Live Preview, navigate with `[[wikilinks]]`, and keep everything offline.

---

## 📥 Download
Don't want to compile the code? Grab the latest release directly:
* **[👉 Download the macOS installer (.dmg)](https://github.com/traxqlf/cactMD/releases/latest)** — Apple Silicon, macOS 14+

**Install:** open the `.dmg`, drag **cactMD** into **Applications**, then launch it. Later updates are offered automatically (menu **cactMD › Check for Updates…**, Sparkle 2).

## ⚠️ Important Note (macOS Gatekeeper)
cactMD is not signed with a Developer ID certificate and is not notarized by Apple. On first launch macOS may say the app cannot be opened because Apple cannot check it for malicious software:
1. Open **System Settings › Privacy & Security**.
2. Scroll down to the cactMD notice and click **Open Anyway**.
3. Confirm with **Open**.

*(You only need to do this on the very first launch, and again after each update.)*

---

## ✨ Features
* 📂 **Local note vault**: open any folder of `.md` files, Finder-like sidebar (outline or grid), tabs, recent notes, rename/move/duplicate, native Finder tags, and incremental FSEvents indexing.
* 🖊️ **Live Preview editor**: Markdown delimiters (`**`, `*`, `` ` ``, `#`, `>`, `[]()`, `[[ ]]`) fade away while typing, yet the saved `.md` stays strictly standard; atomic autosave, native `⌘Z`, image paste/drag into `assets/`, automatic list and task continuation.
* 🔗 **Wikilinks and backlinks**: clickable `[[Note]]` / `[[Note|Alias]]`, `[[` autocompletion, offer to create missing notes, computed backlinks.
* 🕸️ **Note graph** (`⌘G`): visualize links between notes and orphan notes, open a node in one click.
* 🔍 **Search**: fuzzy quick switcher over titles and paths (`⌘O`), full-text vault search (`⌘⇧F`), sidebar filtering.
* 🧩 **Templates** (`⌘⇧N`): built-in *Revision sheet*, *Lab report* and *Technical procedure*, or your own templates in `_templates/` at the vault root (`{{date}}`, `{{datetime}}`, `{{title}}`).
* ✅ **Tasks and outline**: clickable `- [ ]` / `- [x]` checkboxes in both reading and editing modes (the exact file line is updated), heading outline synced with the visible section.
* 📄 **PDF**: PDFs in the folder open in a tab (PDFKit, `⌘F` search, zoom) and Markdown exports to **vector** PDF; `⌘P` prints the note or the displayed PDF page.
* 🎯 **Focus / typewriter mode** (`⌘⌥T`): the current paragraph stays centered, the rest dims.
* 🤖 **On-device AI** (macOS 26+, Apple Intelligence): summarize, proofread or explain the note or the selection, with nothing sent to a server. Corrections apply to the selection with native Undo.
* 📥 **System capture**: select text in any app, then **Services › Capture in cactMD**: the text is appended to `Inbox/Capture-YYYY-MM-DD.md` and the note opens.
* 🍃 **Light and offline**: Markdown rendering, syntax highlighting (Prism) and assets ship inside the app, with no network request needed to read or write your notes.

### ⌨️ Key shortcuts
| Shortcut | Action |
| --- | --- |
| `⌘⇧E` | Toggle Reading / Editing |
| `⌘O` | Quick switcher (titles and paths) |
| `⌘⇧F` | Full-text search |
| `⌘N` / `⌘⇧N` / `⌘⌥N` | New note / from template / new folder |
| `⌘T`, `⌘W`, `⌘1…9` | New tab, close tab, tab n |
| `⌘G` | Note graph |
| `⌘⌥T` | Focus mode |
| `⌘B` `⌘I` `⌘E` `⌘K` | Bold, italic, inline code, link |
| `⌘P` | Print / export as PDF |

## 🛠️ Prerequisites (For Developers)
To build and run this project from the source code, you will need:
* **macOS 14 (Sonoma) or newer**, Apple Silicon.
* **Xcode 15 or newer** (the project builds with Xcode 27.2 / Swift 6.4 with no warnings).
* No manual dependency setup: **Sparkle** is resolved by Swift Package Manager on the first build.
* *Optional:* **macOS 26** for Apple Intelligence features (`FoundationModels`).

## 🚀 Installation & Usage (From Source Code)

1. **Clone the repository to your machine:**
   ```bash
   git clone https://github.com/traxqlf/cactMD.git
   cd cactMD
   ```

2. **Open the project in Xcode and run:**
   ```bash
   open systemMD.xcodeproj
   ```
   Select the `MyApp` scheme, then `⌘R`. Or from the command line:
   ```bash
   xcodebuild -scheme MyApp -destination 'platform=macOS' -derivedDataPath ./build build
   open ./build/Build/Products/Debug/cactMD.app
   ```

3. **Build the production app:**
   ```bash
   xcodebuild -scheme MyApp -configuration Release -destination 'platform=macOS' -derivedDataPath ./build-release build
   ```

4. **Publish a release (zip + signed Sparkle appcast):**
   ```bash
   ./scripts/release.sh 1.0.1
   ```
   The script bumps `CFBundleVersion`, updates `CFBundleShortVersionString`, and produces the installer `dist/cactMD-1.0.1.dmg`, the Sparkle archive `dist/cactMD-1.0.1.zip` and the signed `dist/appcast.xml`. Attach all three files to a GitHub release tagged `v1.0.1`.
