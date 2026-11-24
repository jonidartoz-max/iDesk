import Foundation

/// The ebook reader: an .epub of Files in its own window ("idesk://reader/<path in Files>"). The book is unpacked
/// once into a cache folder, its chapters joined into one scrolling page with the book's own pictures (relative
/// to that folder), a chapter list and font-size buttons.
enum EpubReader {

    static func url(for path: String) -> URL {
        var c = URLComponents()
        c.scheme = "idesk"
        c.host = DesktopPage.reader.rawValue
        c.path = "/" + path
        return c.url ?? DesktopPage.reader.url
    }

    /// The path in Files of the book a reader window shows.
    static func path(of url: URL) -> String? {
        guard url.scheme == "idesk", url.host == DesktopPage.reader.rawValue else { return nil }
        let p = String(url.path.dropFirst())
        return p.isEmpty ? nil : p
    }

    static func isBook(_ file: URL) -> Bool {
        file.pathExtension.lowercased() == "epub"
    }

    /// The folder the book is unpacked into (its pictures and styles load relative to it); the reader's own
    /// address when the book could not be unpacked.
    static func baseURL(for url: URL) -> URL {
        guard let book = book(at: url) else { return url }
        return book.opfDir
    }

    // MARK: Unpacking and parsing

    private struct Book {
        var opfDir: URL          // folder the OPF lives in, inside the cache
        var chapters: [Chapter]  // in reading order
        var title: String
    }

    private struct Chapter {
        var body: String         // the chapter's XHTML, pictures rewritten relative to opfDir
        var name: String         // a title from its first heading, or "Chapter N"
    }

    private static func book(at url: URL) -> Book? {
        guard let path = path(of: url), let file = FileStore.resolve(path),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let unpacked = unpack(file) else { return nil }

        // The container names the OPF (the book's manifest).
        let container = unpacked.appendingPathComponent("META-INF/container.xml")
        guard let containerText = try? String(contentsOf: container, encoding: .utf8),
              let opfPath = firstMatch(#"full-path\s*=\s*"([^"]+)""#, in: containerText) else { return nil }
        let opf = unpacked.appendingPathComponent(opfPath)
        guard let opfText = try? String(contentsOf: opf, encoding: .utf8) else { return nil }
        // Chapter hrefs and everything the page loads are relative to this folder (the page's base).
        let opfDir = opf.deletingLastPathComponent()

        let title = firstMatch(#"<dc:title[^>]*>(.*?)</dc:title>"#, in: opfText) ?? file.deletingPathExtension().lastPathComponent

        // Manifest: id → href (paths here are relative to the OPF's folder).
        var manifest: [String: String] = [:]
        for tag in allMatches(#"<item\b[^>]*>"#, in: opfText) {
            guard let id = firstMatch(#"\bid\s*=\s*"([^"]+)""#, in: tag),
                  let href = firstMatch(#"\bhref\s*=\s*"([^"]+)""#, in: tag) else { continue }
            manifest[id] = href.removingPercentEncoding ?? href
        }
        // Spine: the chapters in reading order.
        var hrefs: [String] = []
        for tag in allMatches(#"<itemref\b[^>]*>"#, in: opfText) {
            guard let idref = firstMatch(#"\bidref\s*=\s*"([^"]+)""#, in: tag),
                  let href = manifest[idref] else { continue }
            hrefs.append(normalize(href))
        }
        guard !hrefs.isEmpty else { return nil }

        // Links between chapters go to their section anchors.
        var spineIndex: [String: Int] = [:]
        for (i, href) in hrefs.enumerated() { spineIndex[href] = i }

        var chapters: [Chapter] = []
        for (i, href) in hrefs.enumerated() {
            let chapterFile = opfDir.appendingPathComponent(href)
            guard let text = try? String(contentsOf: chapterFile, encoding: .utf8) else { continue }
            let chapterDir = String(href.split(separator: "/").dropLast().joined(separator: "/"))
            var body = firstMatch(#"(?s)<body[^>]*>(.*?)</body>"#, in: text) ?? text
            body = strip(#"(?s)<script[^>]*>.*?</script>"#, from: body)
            body = strip(#"(?s)<script[^>]*/>"#, from: body)
            body = strip(#"(?s)<link[^>]*>"#, from: body)
            body = rewriteRefs(in: body, chapterDir: chapterDir, spineIndex: spineIndex)
            let heading = firstMatch(#"(?s)<h[1-3][^>]*>(.*?)</h[1-3]>"#, in: body)
                .map(stripTags) ?? ""
            chapters.append(Chapter(body: body,
                                    name: heading.isEmpty ? String(localized: "Chapter \(i + 1)") : heading))
        }
        guard !chapters.isEmpty else { return nil }
        return Book(opfDir: opfDir, chapters: chapters, title: title)
    }

    /// Unpacks the book once into the tmp cache; the folder while it exists.
    private static func unpack(_ file: URL) -> URL? {
        let stamp = (try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]))
        let key = "\(file.path)-\(stamp?.fileSize ?? 0)-\(Int(stamp?.contentModificationDate?.timeIntervalSince1970 ?? 0))"
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpubCache").appendingPathComponent(String(key.djb2))
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("META-INF/container.xml").path) {
            return folder
        }
        try? FileManager.default.removeItem(at: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Unzip.extract(file, to: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return folder
    }

    // MARK: Markup helpers

    /// "a/b/../c" → "a/c" (paths never leave the unpacked folder: a leading ".." is dropped).
    private static func normalize(_ path: String) -> String {
        var out: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = out.popLast(); continue }
            out.append(String(part))
        }
        return out.joined(separator: "/")
    }

    /// Picture and link addresses are relative to their chapter's file: point pictures at the unpacked copy
    /// (relative to the OPF's folder, the page's base) and turn chapter-to-chapter links into section anchors.
    private static func rewriteRefs(in content: String, chapterDir: String, spineIndex: [String: Int]) -> String {
        let pattern = #"(src|href)\s*=\s*"([^"]+)""#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return content }
        let matches = re.matches(in: content, range: NSRange(content.startIndex..., in: content))
        var result = "", last = content.startIndex
        for m in matches {
            guard let attr = Range(m.range(at: 1), in: content), let refR = Range(m.range(at: 2), in: content) else { continue }
            let ref = String(content[refR])
            let low = ref.lowercased()
            var replacement = ref
            if low.hasPrefix("#") {
                // an anchor inside the book: chapter links already carry one after rewriting; keep plain anchors
            } else if low.hasPrefix("http:") || low.hasPrefix("https:") || low.hasPrefix("data:") || low.hasPrefix("mailto:") {
                // outside the book: keep (the page opens nothing it does not mean to; taps are ignored by script)
            } else {
                let decoded = ref.removingPercentEncoding ?? ref
                let anchor = decoded.split(separator: "#", maxSplits: 1)
                let target = normalize(chapterDir.isEmpty ? String(anchor[0]) : chapterDir + "/" + anchor[0])
                if let chapter = spineIndex[target] {
                    replacement = "#ch-\(chapter)"
                } else if !anchor[0].isEmpty {
                    replacement = target
                }
            }
            result += content[last..<attr.lowerBound] + "\(content[attr])=\"\(replacement)\""
            last = refR.upperBound
        }
        result += content[last...]
        return result
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func strip(_ pattern: String, from text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    private static func stripTags(_ text: String) -> String {
        strip(#"<[^>]+>"#, from: text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: The page

    static func html(for url: URL) -> String {
        guard let book = book(at: url) else { return errorPage(for: url) }
        let strings: [String: Any] = [
            "title": book.title,
            "contents": String(localized: "Contents"),
            "chapters": book.chapters.map { $0.name },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: strings)) ?? Data("{}".utf8)
        let title = book.title
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        var sections = ""
        for (i, chapter) in book.chapters.enumerated() {
            sections += "<section class=\"ch\" id=\"ch-\(i)\">\(chapter.body)</section>\n"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <title>\(title)</title>
        <style>\(css)</style><script>const T = \(String(decoding: data, as: UTF8.self));</script>
        </head><body>
        <div class="bar">
          <select id="toc" onchange="go(this.value)"></select>
          <span class="grow"></span>
          <button onclick="font(-1)">A−</button><button onclick="font(1)">A+</button>
          <span id="pct">0%</span>
        </div>
        <div class="book" id="book">\(sections)</div>
        <script>\(script)</script>
        </body></html>
        """
    }

    private static func errorPage(for url: URL) -> String {
        let path = path(of: url)
        let name = path.map { ($0 as NSString).lastPathComponent } ?? ""
        let missing = path != nil
            ? String(localized: "Could not open “\(name)”. The book may be damaged.")
            : String(localized: "This book is no longer in Files.")
        let escaped = missing
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>\(css)</style></head>
        <body><div class="book"><p class="err">\(escaped)</p></div></body></html>
        """
    }

    private static let css = #"""
    :root { color-scheme: dark; }
    html { -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }
    html, body { margin: 0; height: 100%; background: #1b1b1e; color: #e8e6e3; }
    body { display: flex; flex-direction: column; font: 19px/1.75 Georgia, 'New York', serif; }
    .bar { display: flex; align-items: center; gap: 8px; padding: 8px 14px; background: #232327;
           border-bottom: 1px solid #2f2f34; font: 13px -apple-system, sans-serif; }
    .bar select { max-width: 55%; background: #2c2c31; color: #eee; border: 1px solid #3a3a40;
                  border-radius: 6px; padding: 4px 6px; font: inherit; }
    .bar button { background: #2c2c31; color: #eee; border: 1px solid #3a3a40; border-radius: 6px;
                  padding: 4px 10px; font: inherit; }
    .bar #pct { color: #999; min-width: 42px; text-align: right; }
    .grow { flex: 1; }
    .book { flex: 1; overflow-y: auto; padding: 0 16px; position: relative; }
    .ch { max-width: 660px; margin: 0 auto; padding: 28px 0 8px; }
    .ch img, .ch svg { max-width: 100%; height: auto; }
    .ch p { margin: 0 0 1em; }
    .ch a { color: #8ab4f8; text-decoration: none; }
    .err { max-width: 660px; margin: 60px auto; text-align: center; color: #bbb; font: 15px -apple-system, sans-serif; }
    """#

    private static let script = #"""
    const book = document.getElementById('book'), toc = document.getElementById('toc'), pct = document.getElementById('pct');
    (T.chapters || []).forEach((name, i) => {
      const o = document.createElement('option'); o.value = i; o.textContent = name; toc.appendChild(o);
    });
    function go(i) { const el = document.getElementById('ch-' + i); if (el) el.scrollIntoView(); }
    function font(d) {
      const s = parseFloat(getComputedStyle(document.body).fontSize) || 19;
      const n = Math.min(30, Math.max(13, s + d * 2));
      document.body.style.fontSize = n + 'px';
    }
    book.addEventListener('scroll', () => {
      const max = book.scrollHeight - book.clientHeight;
      pct.textContent = (max > 0 ? Math.round(book.scrollTop / max * 100) : 0) + '%';
      const chs = book.querySelectorAll('.ch');
      for (let i = chs.length - 1; i >= 0; i--) {
        if (chs[i].offsetTop <= book.scrollTop + 40) { toc.value = i; break; }
      }
    });
    document.addEventListener('click', (e) => {
      const a = e.target.closest('a'); if (!a) return;
      e.preventDefault();
      const h = a.getAttribute('href') || '';
      if (h.startsWith('#')) { const el = document.getElementById(h.slice(1)); if (el) el.scrollIntoView(); }
    });
    """#
}

private extension String {
    /// A stable hash for cache folder names.
    var djb2: UInt {
        unicodeScalars.reduce(UInt(5381)) { ($0 &* 33) &+ UInt($1.value) }
    }
}
