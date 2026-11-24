import Foundation

/// The office viewer: a .docx, .xlsx or .pptx of Files in its own window ("idesk://office/<path in Files>").
/// The document is unpacked once into a tmp cache and drawn as a page: Word documents as formatted text,
/// spreadsheets as tables (a dropdown switches sheets), presentations as one section per slide.
/// Older formats (.doc, .xls, .ppt) are binary and cannot be shown.
enum OfficeViewer {

    static func url(for path: String) -> URL {
        var c = URLComponents()
        c.scheme = "idesk"
        c.host = DesktopPage.office.rawValue
        c.path = "/" + path
        return c.url ?? DesktopPage.office.url
    }

    /// The path in Files of the document a viewer window shows.
    static func path(of url: URL) -> String? {
        guard url.scheme == "idesk", url.host == DesktopPage.office.rawValue else { return nil }
        let p = String(url.path.dropFirst())
        return p.isEmpty ? nil : p
    }

    static func canShow(_ file: URL) -> Bool {
        ["docx", "xlsx", "pptx"].contains(file.pathExtension.lowercased())
    }

    // MARK: Unpacking

    private static func unpack(_ file: URL) -> URL? {
        let stamp = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(file.path)-\(stamp?.fileSize ?? 0)-\(Int(stamp?.contentModificationDate?.timeIntervalSince1970 ?? 0))"
        var hash = UInt(5381)
        for s in key.unicodeScalars { hash = hash &* 33 &+ UInt(s.value) }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficeCache").appendingPathComponent(String(hash))
        if FileManager.default.fileExists(atPath: folder.path) { return folder }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Unzip.extract(file, to: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return folder
    }

    // MARK: Word (.docx)

    private static func docxHTML(_ folder: URL) -> String? {
        let doc = folder.appendingPathComponent("word/document.xml")
        guard let xml = try? String(contentsOf: doc, encoding: .utf8) else { return nil }
        var out = ""
        for p in allMatches(#"(?s)<w:p\b[^>]*>.*?</w:p>"#, in: xml) {
            out += docxParagraph(p)
        }
        return out.isEmpty ? nil : "<div class=\"doc\">\(out)</div>"
    }

    private static func docxParagraph(_ p: String) -> String {
        var tag = "p"
        if let style = firstMatch(#"<w:pStyle w:val="([^"]+)""#, in: p) {
            let s = style.lowercased()
            let digits = String(s.filter { $0.isNumber })
            if s.hasPrefix("heading"), let n = Int(digits), (1...4).contains(n) { tag = "h\(n)" }
            else if s == "title" { tag = "h1" }
        }
        let bullet = p.contains("<w:numPr>")
        var text = ""
        for r in allMatches(#"(?s)<w:r\b[^>]*>.*?</w:r>"#, in: p) {
            var run = allMatches(#"(?s)<w:t[^>]*>(.*?)</w:t>"#, in: r).map(esc).joined()
            if r.contains("<w:br") { run += "<br>" }
            if run.isEmpty { continue }
            if r.contains("<w:b/>") || r.contains("<w:b ") { run = "<b>\(run)</b>" }
            if r.contains("<w:i/>") || r.contains("<w:i ") { run = "<i>\(run)</i>" }
            if r.contains("<w:u/>") || r.contains("<w:u ") { run = "<u>\(run)</u>" }
            text += run
        }
        if text.isEmpty { return "" }
        return "<\(tag)>\(bullet ? "• " : "")\(text)</\(tag)>\n"
    }

    // MARK: Excel (.xlsx)

    private struct Sheet {
        var name: String
        var table: String
    }

    private static func xlsxSheets(_ folder: URL) -> [Sheet] {
        // Shared strings, referenced by number from the cells.
        var shared: [String] = []
        if let text = try? String(contentsOf: folder.appendingPathComponent("xl/sharedStrings.xml"), encoding: .utf8) {
            for si in allMatches(#"(?s)<si>(.*?)</si>"#, in: text) {
                shared.append(allMatches(#"(?s)<t[^>]*>(.*?)</t>"#, in: si).map(esc).joined())
            }
        }
        // Sheet names and their files.
        guard let book = try? String(contentsOf: folder.appendingPathComponent("xl/workbook.xml"), encoding: .utf8),
              let rels = try? String(contentsOf: folder.appendingPathComponent("xl/_rels/workbook.xml.rels"), encoding: .utf8)
        else { return [] }
        var targets: [String: String] = [:]
        for tag in allMatches(#"<Relationship\b[^>]*>"#, in: rels) {
            guard let id = firstMatch(#"\bId="([^"]+)""#, in: tag),
                  let target = firstMatch(#"\bTarget="([^"]+)""#, in: tag) else { continue }
            targets[id] = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
        }
        var sheets: [Sheet] = []
        for tag in allMatches(#"<sheet\b[^>]*/?>"#, in: book) {
            guard let name = firstMatch(#"\bname="([^"]+)""#, in: tag),
                  let rid = firstMatch(#"\br:id="([^"]+)""#, in: tag),
                  let target = targets[rid],
                  let xml = try? String(contentsOf: folder.appendingPathComponent(target), encoding: .utf8) else { continue }
            sheets.append(Sheet(name: esc(name), table: xlsxTable(xml, shared: shared)))
        }
        return sheets
    }

    private static func xlsxTable(_ xml: String, shared: [String]) -> String {
        var rows = ""
        for row in allMatches(#"(?s)<row\b[^>]*>.*?</row>"#, in: xml) {
            var cells: [(Int, String)] = []
            for m in allMatchRanges(#"(?s)<c\b([^>]*)>(.*?)</c>"#, in: row) {
                let attrs = m[1], body = m[2]
                let ref = firstMatch(#"\br="([A-Z]+)\d+""#, in: attrs) ?? ""
                let col = columnIndex(ref)
                var value = firstMatch(#"(?s)<v[^>]*>(.*?)</v>"#, in: body) ?? ""
                let type = firstMatch(#"\bt="([^"]+)""#, in: attrs) ?? "n"
                switch type {
                case "s": value = Int(value).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""
                case "b": value = value == "1" ? "TRUE" : "FALSE"
                case "inlineStr": value = allMatches(#"(?s)<t[^>]*>(.*?)</t>"#, in: body).map(esc).joined()
                default: value = esc(value)
                }
                cells.append((col, value))
            }
            let placed = cells.filter { $0.0 >= 0 }
            guard !placed.isEmpty else { continue }
            let width = (placed.map { $0.0 }.max() ?? 0) + 1
            var tds = [String](repeating: "<td></td>", count: width)
            for (col, value) in placed where col < width { tds[col] = "<td>\(value)</td>" }
            rows += "<tr>\(tds.joined())</tr>\n"
        }
        return rows.isEmpty ? "<p class=\"dim\">(empty)</p>" : "<table>\(rows)</table>"
    }

    private static func columnIndex(_ letters: String) -> Int {
        letters.uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
    }

    // MARK: PowerPoint (.pptx)

    private static func pptxHTML(_ folder: URL) -> String? {
        let slidesDir = folder.appendingPathComponent("ppt/slides")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: slidesDir.path) else { return nil }
        let slides = names.filter { $0.hasPrefix("slide") && $0.hasSuffix(".xml") }
            .sorted { (Int($0.dropFirst(5).dropLast(4)) ?? 0) < (Int($1.dropFirst(5).dropLast(4)) ?? 0) }
        var out = ""
        for (i, name) in slides.enumerated() {
            guard let xml = try? String(contentsOf: slidesDir.appendingPathComponent(name), encoding: .utf8) else { continue }
            let text = allMatches(#"(?s)<a:t[^>]*>(.*?)</a:t>"#, in: xml).map(esc).joined(separator: "<br>")
            guard !text.isEmpty else { continue }
            out += "<div class=\"slide\"><h3>\(String(localized: "Slide")) \(i + 1)</h3><p>\(text)</p></div>\n"
        }
        return out.isEmpty ? nil : out
    }

    // MARK: The page

    static func html(for url: URL) -> String {
        let file = path(of: url).flatMap(FileStore.resolve)
        var body: String?
        var sheets: [Sheet] = []
        if let file, FileManager.default.fileExists(atPath: file.path), let folder = unpack(file) {
            switch file.pathExtension.lowercased() {
            case "docx": body = docxHTML(folder)
            case "xlsx": sheets = xlsxSheets(folder); body = sheets.isEmpty ? nil : ""
            case "pptx": body = pptxHTML(folder)
            default: break
            }
        }
        let name = file?.lastPathComponent ?? ""
        guard body != nil || !sheets.isEmpty else { return errorPage(name: name, exists: file != nil) }
        let strings: [String: Any] = [
            "name": name,
            "sheets": sheets.map { $0.name },
            "tables": sheets.map { $0.table },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: strings)) ?? Data("{}".utf8)
        let title = esc(name)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <title>\(title)</title>
        <style>\(css)</style><script>const T = \(String(decoding: data, as: UTF8.self));</script>
        </head><body>
        <div class="bar"><span class="name">\(title)</span><span class="grow"></span>
        <select id="sheet" onchange="sheet(this.value)" hidden></select></div>
        <div class="page" id="page">\(body ?? "")</div>
        <script>\(script)</script>
        </body></html>
        """
    }

    private static func errorPage(name: String, exists: Bool) -> String {
        let text = exists
            ? String(localized: "Could not open “\(name)”.")
            : String(localized: "This document is no longer in Files.")
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>\(css)</style></head>
        <body><div class="page"><p class="dim" style="margin-top:60px;text-align:center">\(esc(text))</p></div></body></html>
        """
    }

    // MARK: Markup helpers

    private static func esc(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        allMatchRanges(pattern, in: text).compactMap { $0.first }
    }

    /// Every match as its capture groups: [whole match, group 1, group 2, …].
    private static func allMatchRanges(_ pattern: String, in text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { m in
            (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
    }

    // MARK: Style and script

    private static let css = #"""
    :root { color-scheme: dark; }
    html { -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }
    html, body { margin: 0; height: 100%; background: #1b1b1e; color: #e8e6e3; }
    body { display: flex; flex-direction: column; font: 14px -apple-system, sans-serif; }
    .bar { display: flex; align-items: center; gap: 8px; padding: 8px 14px; background: #232327;
           border-bottom: 1px solid #2f2f34; }
    .bar .name { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .bar select { background: #2c2c31; color: #eee; border: 1px solid #3a3a40; border-radius: 6px;
                  padding: 4px 6px; font: inherit; }
    .bar select[hidden] { display: none; }
    .grow { flex: 1; }
    .page { flex: 1; overflow: auto; padding: 18px; }
    .doc { max-width: 720px; margin: 0 auto; font: 17px/1.6 Georgia, 'New York', serif; }
    .doc p { margin: 0 0 .9em; }
    .doc h1, .doc h2, .doc h3, .doc h4 { font-family: -apple-system, sans-serif; margin: 1em 0 .5em; }
    table { border-collapse: collapse; margin: 0 auto; }
    td { border: 1px solid #3a3a40; padding: 5px 10px; min-width: 40px; white-space: pre-wrap; }
    tr:first-child td { background: #232327; font-weight: 600; }
    .slide { max-width: 720px; margin: 0 auto 22px; background: #232327; border: 1px solid #2f2f34;
             border-radius: 10px; padding: 16px 20px; }
    .slide h3 { margin: 0 0 8px; font-size: 13px; color: #999; }
    .slide p { margin: 0; font-size: 16px; line-height: 1.55; }
    .dim { color: #888; }
    """#

    private static let script = #"""
    const sel = document.getElementById('sheet'), page = document.getElementById('page');
    if ((T.sheets || []).length) {
      (T.sheets || []).forEach((name, i) => {
        const o = document.createElement('option'); o.value = i; o.textContent = name; sel.appendChild(o);
      });
      sel.hidden = false;
      page.innerHTML = T.tables[0] || '';
    }
    function sheet(i) { page.innerHTML = T.tables[i] || ''; }
    """#
}
