import Foundation

nonisolated enum MarkdownHTMLRenderer {
    static func fallbackSkeletonHTML() -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>:root{color-scheme:light dark}body{margin:0;background:#fff;color:#222;font-family:-apple-system,sans-serif}
        @media(prefers-color-scheme:dark){body{background:#1e1e1e;color:#dadada}}
        #content{width:100%;max-width:700px;margin:0 auto;padding:28px clamp(20px,5vw,48px) 80px;font-size:15.5px;line-height:1.6}
        body.sidebar-hidden #content{max-width:clamp(700px,calc(100% - 360px),960px)}</style></head>
        <body><div id="content"></div><script>function setContent(h){document.getElementById('content').innerHTML=h||'';window.scrollTo(0,0);}</script></body></html>
        """
    }

    static func bodyHTML(note: LoadedNote, backlinks: [NoteReference]) -> String {
        var out = ""
        let title = note.url.deletingPathExtension().lastPathComponent
        out += "<h1 class=\"note-title\">\(escape(title))</h1>"
        if !note.frontmatter.isEmpty {
            out += frontmatterHTML(note.frontmatter)
        }
        out += blocksHTML(note.blocks)
        if !backlinks.isEmpty {
            out += backlinksHTML(backlinks)
        }
        return out
    }

    private static func frontmatterHTML(_ fields: [FrontmatterField]) -> String {
        var out = "<details class=\"frontmatter-container\"><summary><span class=\"fm-caret\">▸</span><span>Propriétés</span></summary><div class=\"frontmatter-body\">"
        for field in fields {
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            out += "<div class=\"fm-row\"><div class=\"fm-key\">\(escape(field.key))</div><div class=\"fm-value\">\(escape(value.isEmpty ? "—" : value))</div></div>"
        }
        out += "</div></details>"
        return out
    }

    private static func backlinksHTML(_ backlinks: [NoteReference]) -> String {
        var out = "<section class=\"embedded-backlinks\"><h3>Rétro-liens (\(backlinks.count))</h3>"
        for ref in backlinks {
            let href = "systemmd://note?path=\(urlEncode(ref.url.path))"
            out += "<a class=\"backlink-item\" href=\"\(escapeAttribute(href))\">\(escape(ref.name))"
            if !ref.folder.isEmpty {
                out += "<span class=\"path\">\(escape(ref.folder))</span>"
            }
            out += "</a>"
        }
        out += "</section>"
        return out
    }

    private static func blocksHTML(_ blocks: [MarkdownBlock]) -> String {
        var out = ""
        for block in blocks { out += blockHTML(block) }
        return out
    }

    private static func blockHTML(_ block: MarkdownBlock) -> String {
        switch block.kind {
        case let .heading(level, text):
            let l = min(6, max(1, level))
            // The block id is the outline's anchor: it lets the page scroll to a
            // heading and report the section in view back to the app.
            return "<h\(l) data-heading-id=\"\(block.id)\">\(inlineHTML(text))</h\(l)>"
        case let .paragraph(text):
            let inner = inlineHTML(text)
            if inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
            return "<p>\(inner)</p>"
        case let .codeBlock(language, code, _):
            return codeBlockHTML(language: language, code: code)
        case let .blockQuote(children):
            return "<blockquote>\(blocksHTML(children))</blockquote>"
        case let .list(ordered, startIndex, items):
            return listHTML(ordered: ordered, startIndex: startIndex, items: items)
        case let .table(alignments, headers, rows):
            return tableHTML(alignments: alignments, headers: headers, rows: rows)
        case let .image(url, alt):
            let src = escapeAttribute(url.absoluteString)
            let a = escapeAttribute(alt)
            return "<p><img src=\"\(src)\" alt=\"\(a)\"></p>"
        case .thematicBreak:
            return "<hr>"
        }
    }

    private static func codeBlockHTML(language: String?, code: String) -> String {
        let langRaw = (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let prismLang = prismLanguage(langRaw)
        let displayLang = displayLanguage(langRaw)
        let langClass = prismLang.isEmpty ? "" : " class=\"language-\(escapeAttribute(prismLang))\""
        let preClass = displayLang.isEmpty ? "" : " class=\"has-lang\""
        let header: String
        if displayLang.isEmpty {
            header = "<div class=\"code-header\"><button class=\"code-copy\" title=\"Copier\" aria-label=\"Copier\">\(copySVG)</button></div>"
        } else {
            header = "<div class=\"code-header\"><span class=\"code-lang\">\(escape(displayLang))</span><button class=\"code-copy\" title=\"Copier\" aria-label=\"Copier\">\(copySVG)</button></div>"
        }
        return "<pre\(preClass)>\(header)<code\(langClass)>\(escape(code))</code></pre>"
    }

    private static func prismLanguage(_ lang: String) -> String {
        switch lang.lowercased() {
        case "": return ""
        case "js": return "javascript"
        case "ts": return "typescript"
        case "sh", "shell", "zsh": return "bash"
        case "yml": return "yaml"
        case "html", "xml", "svg": return "markup"
        case "objc", "objective-c": return "c"
        case "c++": return "cpp"
        default: return lang.lowercased()
        }
    }

    private static func displayLanguage(_ lang: String) -> String {
        let t = lang.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        switch t.lowercased() {
        case "js", "javascript": return "JavaScript"
        case "ts", "typescript": return "TypeScript"
        case "bash", "sh", "shell", "zsh": return "Bash"
        case "sql": return "SQL"
        case "swift": return "Swift"
        case "python", "py": return "Python"
        case "json": return "JSON"
        case "yaml", "yml": return "YAML"
        case "css": return "CSS"
        case "html", "xml", "markup": return "HTML"
        case "c": return "C"
        case "cpp", "c++": return "C++"
        default: return t.prefix(1).uppercased() + t.dropFirst()
        }
    }

    private static let copySVG = """
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>
    """

    private static func listHTML(ordered: Bool, startIndex: Int, items: [MarkdownListItem]) -> String {
        let hasTask = items.contains { $0.checkbox != nil }
        let tag = ordered ? "ol" : "ul"
        let cls = hasTask ? " class=\"contains-task-list\"" : ""
        let startAttr = (ordered && startIndex != 1) ? " start=\"\(startIndex)\"" : ""
        var out = "<\(tag)\(cls)\(startAttr)>"
        for item in items {
            if let checked = item.checkbox {
                let lineAttr = item.sourceLine.map { " data-line=\"\($0)\"" } ?? ""
                let checkedAttr = checked ? " checked" : ""
                let liClass = checked ? " class=\"task-list-item is-checked\"" : " class=\"task-list-item\""
                out += "<li\(liClass)><input class=\"task-list-item-checkbox\" type=\"checkbox\"\(checkedAttr)\(lineAttr)><div class=\"task-list-item-content\">\(blocksHTML(item.blocks))</div></li>"
            } else {
                out += "<li>\(blocksHTML(item.blocks))</li>"
            }
        }
        out += "</\(tag)>"
        return out
    }

    private static func tableHTML(alignments: [MarkdownTableAlignment], headers: [LazyAttributed], rows: [[LazyAttributed]]) -> String {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        func alignStyle(_ column: Int) -> String {
            guard column < alignments.count else { return "" }
            switch alignments[column] {
            case .left: return ""
            case .center: return " style=\"text-align:center\""
            case .right: return " style=\"text-align:right\""
            }
        }
        var out = "<table><thead><tr>"
        for c in 0..<columnCount {
            let cell = c < headers.count ? inlineHTML(headers[c]) : ""
            out += "<th\(alignStyle(c))>\(cell)</th>"
        }
        out += "</tr></thead><tbody>"
        for row in rows {
            out += "<tr>"
            for c in 0..<columnCount {
                let cell = c < row.count ? inlineHTML(row[c]) : ""
                out += "<td\(alignStyle(c))>\(cell)</td>"
            }
            out += "</tr>"
        }
        out += "</tbody></table>"
        return out
    }

    private static func inlineHTML(_ lazy: LazyAttributed) -> String {
        switch lazy.content {
        case let .runs(runs, _, _):
            var out = ""
            for run in runs { out += runHTML(run) }
            return out
        case let .code(code, _):
            return "<code>\(escape(code))</code>"
        }
    }

    private static func runHTML(_ run: MarkdownInline) -> String {
        var text = escape(run.text)
        if run.text.isEmpty { return "" }
        switch run.kind {
        case .code:
            text = "<code>\(text)</code>"
        case .link:
            let raw = run.destination?.absoluteString ?? "#"
            let href = escapeAttribute(raw)
            let isExternal = raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://")
            let cls = isExternal ? " class=\"external-link\"" : ""
            text = "<a\(cls) href=\"\(href)\">\(text)</a>"
        case .wikilink:
            let href = escapeAttribute(run.destination?.absoluteString ?? "#")
            text = "<a class=\"internal-link\" href=\"\(href)\">\(text)</a>"
        case .tag:
            let href = escapeAttribute(run.destination?.absoluteString ?? "#")
            text = "<a class=\"tag\" href=\"\(href)\">#\(text)</a>"
        case .image:
            let src = escapeAttribute(run.destination?.absoluteString ?? "")
            let alt = escapeAttribute(run.text)
            text = src.isEmpty ? "<em>\(text)</em>" : "<img src=\"\(src)\" alt=\"\(alt)\">"
        case .html:
            text = escape(run.text)
        case .text:
            break
        }
        if run.bold { text = "<strong>\(text)</strong>" }
        if run.italic { text = "<em>\(text)</em>" }
        if run.strikethrough { text = "<del>\(text)</del>" }
        return text
    }

    static func jsStringLiteral(_ string: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "\"\(escaped)\""
    }

    private static func escape(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        for ch in string {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.append(ch)
            }
        }
        return out
    }

    private static func escapeAttribute(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        for ch in string {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    private static func urlEncode(_ string: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
