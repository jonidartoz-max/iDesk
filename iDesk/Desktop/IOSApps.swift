import UIKit

@_silgen_name("_dyld_get_image_name")
private func dyldImageName(_ index: UInt32) -> UnsafePointer<CChar>?

/// An iPhone app iDesk can open (0.9.20):
/// - .container: an app inside zContainer/LiveContainer — visible when iDesk itself runs there,
///   opened through the container's own launch URL.
/// - .catalog: a known App Store / system app, detected through its URL scheme (canOpenURL).
/// - .manual: name + scheme the user typed in themselves.
/// Detecting every installed app is impossible on a non-jailbroken iPhone; the container scan and
/// the scheme catalog are the two doors Apple left open.
struct IOSAppEntry: Identifiable, Equatable, Sendable {
    enum Source: String, Sendable { case container, catalog, manual }
    let id: String              // bundle id, or "manual:<scheme>"
    let name: String
    let bundleID: String?
    let scheme: String?         // launch scheme (catalog / manual)
    let source: Source
    let containerFolder: String?  // LiveContainer data container, when known
    let bundlePath: String?       // container apps: where the .app (and its icon files) live
    let symbol: String            // placeholder glyph until an icon arrives
    let hue: Double
}

final class IOSAppsStore: ObservableObject {
    static let shared = IOSAppsStore()

    @Published private(set) var entries: [IOSAppEntry] = []
    @Published private(set) var icons: [String: UIImage] = [:]
    /// Non-nil when iDesk itself is running inside LiveContainer/zContainer: the container's URL scheme.
    @Published private(set) var containerScheme: String?

    private var iconTried = Set<String>()
    private static let manualKey = "iDesk.iosApps.manual.v1"

    /// Schemes declared in Info.plist's LSApplicationQueriesSchemes. Keep the two lists in sync:
    /// canOpenURL always answers false for a scheme that is not declared.
    static let declaredSchemes: Set<String> = [
        "whatsapp", "tg", "instagram", "snssdk1128", "fb", "twitter", "youtube", "spotify",
        "gojek", "grab", "shopeeid", "tokopedia", "dana", "ovo", "nflx", "discord", "line",
        "capcut", "pinterest", "googlegmail", "comgooglemaps", "googlechrome", "googledrive",
        "zoomus", "roblox", "pubgm", "mobilelegends", "reddit", "snapchat", "twitch",
        "googlephotos", "google", "duolingo",
        "app-settings", "tel", "sms", "mailto", "maps", "music", "photos-redirect", "facetime",
        "itms-apps", "shareddocuments", "mobilenotes", "calshow",
        "zcontainer", "livecontainer", "livecontainer2", "livecontainer3",
    ]

    struct CatalogApp: Sendable {
        let name: String, bundleID: String, scheme: String, symbol: String, hue: Double
    }

    /// Popular apps with their URL schemes. Schemes are community knowledge; canOpenURL decides
    /// what is really installed, so a wrong entry can only hide an app, never launch a wrong one.
    static let catalog: [CatalogApp] = [
        .init(name: "WhatsApp", bundleID: "net.whatsapp.WhatsApp", scheme: "whatsapp", symbol: "phone.fill", hue: 0.36),
        .init(name: "Telegram", bundleID: "ph.telegra.Telegraph", scheme: "tg", symbol: "paperplane.fill", hue: 0.56),
        .init(name: "Instagram", bundleID: "com.burbn.instagram", scheme: "instagram", symbol: "camera.fill", hue: 0.9),
        .init(name: "TikTok", bundleID: "com.ss.iphone.ugc.Ame", scheme: "snssdk1128", symbol: "music.note", hue: 0.72),
        .init(name: "Facebook", bundleID: "com.facebook.Facebook", scheme: "fb", symbol: "hand.thumbsup.fill", hue: 0.6),
        .init(name: "X", bundleID: "com.atebits.Tweetie2", scheme: "twitter", symbol: "at", hue: 0.6),
        .init(name: "YouTube", bundleID: "com.google.ios.youtube", scheme: "youtube", symbol: "play.rectangle.fill", hue: 0.0),
        .init(name: "Spotify", bundleID: "com.spotify.client", scheme: "spotify", symbol: "waveform", hue: 0.38),
        .init(name: "Gojek", bundleID: "com.go-jek.ios", scheme: "gojek", symbol: "moped.fill", hue: 0.36),
        .init(name: "Grab", bundleID: "com.grabtaxi.iphone", scheme: "grab", symbol: "car.fill", hue: 0.38),
        .init(name: "Shopee", bundleID: "com.beeasy.shopee.id", scheme: "shopeeid", symbol: "bag.fill", hue: 0.05),
        .init(name: "Tokopedia", bundleID: "com.tokopedia.Tokopedia", scheme: "tokopedia", symbol: "cart.fill", hue: 0.35),
        .init(name: "DANA", bundleID: "id.dana.app", scheme: "dana", symbol: "wallet.pass.fill", hue: 0.56),
        .init(name: "OVO", bundleID: "ovo.id", scheme: "ovo", symbol: "creditcard.fill", hue: 0.75),
        .init(name: "Netflix", bundleID: "com.netflix.Netflix", scheme: "nflx", symbol: "tv.fill", hue: 0.0),
        .init(name: "Discord", bundleID: "com.hammerandchisel.discord", scheme: "discord", symbol: "message.badge.fill", hue: 0.68),
        .init(name: "LINE", bundleID: "jp.naver.line", scheme: "line", symbol: "message.fill", hue: 0.36),
        .init(name: "CapCut", bundleID: "com.lemon.lvoverseas", scheme: "capcut", symbol: "scissors", hue: 0.58),
        .init(name: "Pinterest", bundleID: "com.pinterest", scheme: "pinterest", symbol: "pin.fill", hue: 0.97),
        .init(name: "Gmail", bundleID: "com.google.Gmail", scheme: "googlegmail", symbol: "envelope.fill", hue: 0.0),
        .init(name: "Google Maps", bundleID: "com.google.Maps", scheme: "comgooglemaps", symbol: "map.fill", hue: 0.36),
        .init(name: "Chrome", bundleID: "com.google.Chrome", scheme: "googlechrome", symbol: "globe", hue: 0.55),
        .init(name: "Google Drive", bundleID: "com.google.Drive", scheme: "googledrive", symbol: "folder.fill", hue: 0.45),
        .init(name: "Zoom", bundleID: "us.zoom.videomeetings", scheme: "zoomus", symbol: "video.fill", hue: 0.58),
        .init(name: "Roblox", bundleID: "com.roblox.robloxmobile", scheme: "roblox", symbol: "cube.fill", hue: 0.95),
        .init(name: "PUBG Mobile", bundleID: "com.tencent.ig", scheme: "pubgm", symbol: "scope", hue: 0.08),
        .init(name: "Mobile Legends", bundleID: "com.mobile.legends", scheme: "mobilelegends", symbol: "gamecontroller.fill", hue: 0.6),
        .init(name: "Reddit", bundleID: "com.reddit.Reddit", scheme: "reddit", symbol: "bubble.left.and.bubble.right.fill", hue: 0.05),
        .init(name: "Snapchat", bundleID: "com.toyopagroup.picaboo", scheme: "snapchat", symbol: "camera.viewfinder", hue: 0.14),
        .init(name: "Twitch", bundleID: "tv.twitch", scheme: "twitch", symbol: "play.tv.fill", hue: 0.75),
        .init(name: "Google Photos", bundleID: "com.google.photos", scheme: "googlephotos", symbol: "photo.on.rectangle", hue: 0.12),
        .init(name: "Google", bundleID: "com.google.googlemobile", scheme: "google", symbol: "magnifyingglass", hue: 0.5),
        .init(name: "Duolingo", bundleID: "com.duolingo.DuolingoMobile", scheme: "duolingo", symbol: "character.bubble.fill", hue: 0.3),
        .init(name: "Settings", bundleID: "com.apple.Preferences", scheme: "app-settings", symbol: "gearshape.fill", hue: 0.6),
        .init(name: "Phone", bundleID: "com.apple.mobilephone", scheme: "tel", symbol: "phone.fill", hue: 0.36),
        .init(name: "Messages", bundleID: "com.apple.MobileSMS", scheme: "sms", symbol: "message.fill", hue: 0.36),
        .init(name: "Mail", bundleID: "com.apple.mobilemail", scheme: "mailto", symbol: "envelope.fill", hue: 0.56),
        .init(name: "Maps", bundleID: "com.apple.Maps", scheme: "maps", symbol: "map.fill", hue: 0.36),
        .init(name: "Music", bundleID: "com.apple.Music", scheme: "music", symbol: "music.note", hue: 0.96),
        .init(name: "Photos", bundleID: "com.apple.mobileslideshow", scheme: "photos-redirect", symbol: "photo.fill", hue: 0.1),
        .init(name: "FaceTime", bundleID: "com.apple.facetime", scheme: "facetime", symbol: "video.fill", hue: 0.36),
        .init(name: "App Store", bundleID: "com.apple.AppStore", scheme: "itms-apps", symbol: "applelogo", hue: 0.56),
        .init(name: "Files", bundleID: "com.apple.DocumentsApp", scheme: "shareddocuments", symbol: "folder.fill", hue: 0.6),
        .init(name: "Notes", bundleID: "com.apple.mobilenotes", scheme: "mobilenotes", symbol: "note.text", hue: 0.12),
        .init(name: "Calendar", bundleID: "com.apple.mobilecal", scheme: "calshow", symbol: "calendar", hue: 0.0),
    ]

    // MARK: Refresh

    /// Re-scan the world: apps inside the container (if we run in one), catalog apps that answer
    /// canOpenURL, and the user's manual entries. Hops to the main queue when needed.
    func refresh() {
        if Thread.isMainThread { refreshOnMain() } else { DispatchQueue.main.async { self.refreshOnMain() } }
    }

    private func refreshOnMain() {
        let container = Self.scanContainer()
        containerScheme = container?.scheme
        var seen = Set<String>()
        var out: [IOSAppEntry] = container?.apps ?? []
        for e in out { seen.insert(e.id) }
        let insideContainer = container != nil
        for c in Self.catalog {
            guard !seen.contains(c.bundleID) else { continue }
            // Inside a container canOpenURL answers for the host process and may lie about other
            // schemes; trust a yes, but a no means "unknown" there, so the entry stays visible.
            let probe = URL(string: "\(c.scheme)://").map { UIApplication.shared.canOpenURL($0) } ?? false
            if probe || insideContainer {
                seen.insert(c.bundleID)
                out.append(IOSAppEntry(id: c.bundleID, name: c.name, bundleID: c.bundleID, scheme: c.scheme,
                                       source: .catalog, containerFolder: nil, bundlePath: nil,
                                       symbol: c.symbol, hue: c.hue))
            }
        }
        for e in Self.loadManual() where seen.insert(e.id).inserted { out.append(e) }
        entries = out
        loadIcons()
    }

    // MARK: Opening

    func open(_ entry: IOSAppEntry) {
        let url: URL?
        switch entry.source {
        case .container:
            var s = (containerScheme ?? "zcontainer") + "://livecontainer-launch?bundle-name=" + (entry.bundleID ?? entry.id)
            if let folder = entry.containerFolder { s += "&container-folder-name=" + folder }
            url = URL(string: s)
        case .catalog, .manual:
            url = entry.scheme.flatMap { URL(string: "\($0)://") }
        }
        guard let url else { return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { ok in
                if !ok { NotificationCenter.default.post(name: .iosAppOpenFailed, object: entry.name) }
            }
        }
    }

    // MARK: Manual entries

    var manualEntries: [IOSAppEntry] { Self.loadManual() }

    func addManual(name: String, scheme: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        var scheme = scheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for tail in ["://", ":"] { if scheme.hasSuffix(tail) { scheme = String(scheme.dropLast(tail.count)) } }
        guard !name.isEmpty, !scheme.isEmpty,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "+" }) else { return }
        var rows = UserDefaults.standard.array(forKey: Self.manualKey) as? [[String: String]] ?? []
        rows.removeAll { $0["scheme"] == scheme }
        rows.append(["name": name, "scheme": scheme])
        UserDefaults.standard.set(rows, forKey: Self.manualKey)
        refresh()
    }

    func removeManual(_ entry: IOSAppEntry) {
        var rows = UserDefaults.standard.array(forKey: Self.manualKey) as? [[String: String]] ?? []
        rows.removeAll { "manual:" + ($0["scheme"] ?? "") == entry.id }
        UserDefaults.standard.set(rows, forKey: Self.manualKey)
        refresh()
    }

    private static func loadManual() -> [IOSAppEntry] {
        let rows = UserDefaults.standard.array(forKey: manualKey) as? [[String: String]] ?? []
        return rows.compactMap { row in
            guard let name = row["name"], let scheme = row["scheme"] else { return nil }
            return IOSAppEntry(id: "manual:" + scheme, name: name, bundleID: nil, scheme: scheme,
                               source: .manual, containerFolder: nil, bundlePath: nil,
                               symbol: "link", hue: 0.55)
        }
    }

    // MARK: Icons

    private func loadIcons() {
        for entry in entries where icons[entry.id] == nil && !iconTried.contains(entry.id) {
            iconTried.insert(entry.id)
            Task { [weak self] in
                guard let data = await Self.iconData(for: entry), let image = UIImage(data: data) else { return }
                DispatchQueue.main.async { self?.icons[entry.id] = image }
            }
        }
    }

    /// Icon pixels: from the app bundle itself (container apps), else the App Store's artwork.
    nonisolated private static func iconData(for entry: IOSAppEntry) async -> Data? {
        let fm = FileManager.default
        if let path = entry.bundlePath {
            let bundle = URL(fileURLWithPath: path, isDirectory: true)
            if let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Info.plist")),
               let icon = largestIcon(in: bundle, info: info) { return try? Data(contentsOf: icon) }
        }
        guard let bundleID = entry.bundleID else { return nil }
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IOSAppIcons", isDirectory: true)
        try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let file = cache.appendingPathComponent(bundleID + ".png")
        if let data = try? Data(contentsOf: file) { return data }
        // Exact lookup first; if the bundle id guess was wrong, fall back to a store search by name.
        let attempts = [
            "https://itunes.apple.com/lookup?bundleId=\(bundleID)&country=id",
            "https://itunes.apple.com/search?term=\(entry.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? entry.name)&country=id&entity=software&limit=1",
        ]
        for attempt in attempts {
            guard let url = URL(string: attempt),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]], let first = results.first,
                  let art = (first["artworkUrl512"] as? String) ?? (first["artworkUrl100"] as? String),
                  let artURL = URL(string: art),
                  let (png, _) = try? await URLSession.shared.data(from: artURL) else { continue }
            try? png.write(to: file)
            return png
        }
        return nil
    }

    /// The largest icon PNG declared by an app bundle's Info.plist (same rule as the IPA guests).
    nonisolated private static func largestIcon(in bundle: URL, info: NSDictionary) -> URL? {
        var names: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            if let icons = info[key] as? [String: Any],
               let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
               let files = primary["CFBundleIconFiles"] as? [String] { names += files }
        }
        if let files = info["CFBundleIconFiles"] as? [String] { names += files }
        guard !names.isEmpty,
              let all = try? FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: [.fileSizeKey])
        else { return nil }
        return all
            .filter { url in url.pathExtension.lowercased() == "png" && names.contains { url.lastPathComponent.hasPrefix($0) } }
            .max { a, b in
                let sa = (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let sb = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return sa < sb
            }
    }

    // MARK: Container detection (zContainer / LiveContainer)

    /// When iDesk runs as a LiveContainer/zContainer guest, the guest's home folder is the app's data
    /// container and guest containers are not sandboxed from each other, so the host's
    /// Documents/Applications folder — one .app per installed app, each carrying LCAppInfo.plist —
    /// is readable. Walk up from home until that folder appears; nil when iDesk runs natively.
    nonisolated static func scanContainer() -> (scheme: String, apps: [IOSAppEntry])? {
        let fm = FileManager.default
        func markedApps(_ dir: URL) -> [URL]? {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
            let bundles = items.filter { $0.pathExtension == "app" }
            return bundles.contains { fm.fileExists(atPath: $0.appendingPathComponent("LCAppInfo.plist").path) } ? bundles : nil
        }
        var appsDir: URL?
        var dir = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        for _ in 0..<6 {
            if let bundles = markedApps(dir.appendingPathComponent("Applications", isDirectory: true)) {
                appsDir = dir.appendingPathComponent("Applications", isDirectory: true); _ = bundles; break
            }
            dir = dir.deletingLastPathComponent()
        }
        if appsDir == nil {
            // "Shared" LiveContainer apps live in the group container instead.
            for group in ["group.app.reiko.zcontainer", "group.com.kdt.livecontainer"] {
                let candidate = fm.containerURL(forSecurityApplicationGroupIdentifier: group)?
                    .appendingPathComponent("LiveContainer/Applications", isDirectory: true)
                if let candidate, markedApps(candidate) != nil { appsDir = candidate; break }
            }
        }
        guard let appsDir else { return nil }

        // The host's own URL scheme (zcontainer, livecontainer, ...) from its Info.plist; the launch
        // URL path (livecontainer-launch) is the same across the family.
        var scheme = "zcontainer"
        if let c = dyldImageName(0) {
            let plist = URL(fileURLWithPath: String(cString: c)).deletingLastPathComponent()
                .appendingPathComponent("Info.plist")
            if let info = NSDictionary(contentsOf: plist),
               let types = info["CFBundleURLTypes"] as? [[String: Any]],
               let firstType = types.first,
               let schemes = firstType["CFBundleURLSchemes"] as? [String],
               let first = schemes.first {
                scheme = first
            }
        }

        let ownID = Bundle.main.bundleIdentifier
        let apps = ((try? fm.contentsOfDirectory(at: appsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" }
            .compactMap { bundle -> IOSAppEntry? in
                guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Info.plist")),
                      let id = info["CFBundleIdentifier"] as? String, id != ownID else { return nil }
                let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                    ?? bundle.deletingPathExtension().lastPathComponent
                let lc = NSDictionary(contentsOf: bundle.appendingPathComponent("LCAppInfo.plist"))
                let folder = lc?["LCDataUUID"] as? String
                return IOSAppEntry(id: id, name: name, bundleID: id, scheme: nil, source: .container,
                                   containerFolder: folder, bundlePath: bundle.path,
                                   symbol: "app.fill", hue: 0.55)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (scheme, apps)
    }
}

extension Notification.Name {
    static let iosAppOpenFailed = Notification.Name("iDesk.iosAppOpenFailed")
}
