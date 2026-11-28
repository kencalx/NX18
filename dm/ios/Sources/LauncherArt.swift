// What the build packs for the settings screen besides its settings (dm/ios/tools/build_ipa.sh), each optional and read defensively: the key art (dm/art.jpg), the game's logo (dm/logo.png,
// shown in place of its name), the "About this game"
// text (dm/about.json), the player's manual (dm/manual.pdf) and the game's own guide (the offline HTML pages beside the RomFS, the folder hle_web.c serves: DM_HTML, else html beside
// DM_ROMFS, else the bundle's html). The art, the text and the manual are app-wide (<App>/dm), but the folder the launcher's list came from (DM_APP_DM, a program's dm/p<N>) is
// looked in first. The art's average colour, for the screen's tint, and the wash's blur are worked out on the CPU (NX18Palette.average, NX18Blur, Core Graphics): never a Metal
// device or a Core Image context here, which would come before the game's first device (Launcher.swift metalDeviceMade)
import Foundation
import UIKit

// about.json: the game's eShop page text, from a public title database (scripts/game_art.py). Every field may be missing or of another type; such a field is nil
struct LauncherAbout: Decodable, Equatable, Sendable {
    var name, intro, description, publisher, releaseDate, source: String?

    init(name: String? = nil, intro: String? = nil, description: String? = nil, publisher: String? = nil, releaseDate: String? = nil, source: String? = nil) {
        self.name = name; self.intro = intro; self.description = description; self.publisher = publisher; self.releaseDate = releaseDate; self.source = source
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ k: CodingKeys) -> String? {
            guard let s = (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        name = text(.name); intro = text(.intro); description = text(.description); publisher = text(.publisher); releaseDate = text(.releaseDate); source = text(.source)
    }
    enum CodingKeys: String, CodingKey { case name, intro, description, publisher, releaseDate, source }

    var hasText: Bool { intro != nil || description != nil || publisher != nil || released != nil }
    // The release date as a date ("YYYY-MM-DD"), shown in the reader's own format
    var released: Date? {
        guard let r = releaseDate else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: r)
    }
    // Where the text came from, as the sheet's last line: game_art.py's "titledb" (a public title database's copy of the eShop page) shows as "From the game's eShop page"
    var sourceLine: String? { source.map { $0 == "titledb" ? "From the game's eShop page" : "From \($0)" } }
}

// facts.json (dm/tools/about_facts.py, gate-ui §18.1): the control data's age ratings by body, the profile's tested line and known issue, and the packed switchable mods'
// credits. Every part optional; a field of another type is left out
struct LauncherFacts: Decodable, Equatable, Sendable {
    struct Mod: Decodable, Equatable, Sendable, Identifiable {
        var role: String, name: String
        var author: String? = nil, link: String? = nil, license: String? = nil
        var id: String { role + "/" + name }
        var url: URL? { link.flatMap { $0.hasPrefix("https://") || $0.hasPrefix("http://") ? URL(string: $0) : nil } }   // only a web link
    }
    var ratings: [String: Int] = [:]
    var tested: String? = nil
    var knownIssue: String? = nil
    var mods: [Mod] = []
    enum CodingKeys: String, CodingKey { case ratings, tested, knownIssue = "known_issue", mods }

    init(ratings: [String: Int] = [:], tested: String? = nil, knownIssue: String? = nil, mods: [Mod] = []) {
        self.ratings = ratings; self.tested = tested; self.knownIssue = knownIssue; self.mods = mods
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ratings = ((try? c.decodeIfPresent([String: Int].self, forKey: .ratings)) ?? nil) ?? [:]
        func text(_ k: CodingKeys) -> String? { ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil).flatMap { $0.isEmpty ? nil : $0 } }
        tested = text(.tested); knownIssue = text(.knownIssue).map { String($0.prefix(80)) }
        mods = ((try? c.decodeIfPresent([Mod].self, forKey: .mods)) ?? nil) ?? []
    }

    // The rating body for the device's region setting (not its location): US, CA ESRB; DE USK; JP CERO; AU ACB; BR ClassInd; KR GRAC; else PEGI. The region's own body first,
    // then PEGI, then any other the game has
    static func body(region: String?) -> String {
        switch region ?? "" {
        case "US", "CA": return "ESRB"
        case "DE": return "USK"
        case "JP": return "CERO"
        case "AU": return "ACB"
        case "BR": return "ClassInd"
        case "KR": return "GRAC"
        default: return "PEGI"
        }
    }
    // "Ages 10 and up (ESRB)"; "All ages (CERO)" for 0; nil when unrated
    func ratingLine(region: String? = Locale.current.region?.identifier) -> String? {
        let want = Self.body(region: region)
        guard let (body, age) = [want, "PEGI"].lazy.compactMap({ b in self.ratings[b].map { (b, $0) } }).first ?? ratings.sorted(by: { $0.key < $1.key }).first.map({ ($0.key, $0.value) })
        else { return nil }
        return age == 0 ? "All ages (\(body))" : "Ages \(age) and up (\(body))"
    }
}

struct LauncherContent: Equatable, Sendable {
    var art: URL?
    var artFocus: URL?     // dm/art_focus.json, the build's framing of the art (ArtFocus.swift; the player's own, in the preferences, comes first)
    var logo: URL?         // dm/logo.png, the game's title wordmark with transparency (scripts/game_art.py: SteamGridDB's, or the player's --logo)
    var about: LauncherAbout?
    var facts = LauncherFacts()   // dm/facts.json (About's age rating, tested line, known issue, mod credits)
    var manual: URL?
    var guide: URL?        // the guide's index.html, in the player's language when the guide has it
    var guideRoot: URL?    // the folder the guide's pages may read (its .htdocs)

    var hasGuide: Bool { guide != nil || manual != nil }
    var hasAbout: Bool { about?.hasText ?? false }

    // The files for the launcher's list in dir (DM_APP_DM or <App>/dm), in the bundle's dm folder and guide folder, for the game language lang (DM_LANG's value)
    static func find(dir: URL?, lang: String?, environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main) -> LauncherContent {
        let fm = FileManager.default
        let appDM = bundle.resourceURL?.appendingPathComponent("dm")
        let places = [dir, appDM].compactMap { $0 }.reduce(into: [URL]()) { if !$0.contains($1.standardizedFileURL) { $0.append($1.standardizedFileURL) } }
        func file(_ name: String) -> URL? {
            places.lazy.map { $0.appendingPathComponent(name) }.first { u in
                var d: ObjCBool = false
                return fm.fileExists(atPath: u.path, isDirectory: &d) && !d.boolValue && ((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
            }
        }
        var c = LauncherContent()
        c.art = file("art.jpg")
        c.artFocus = file(ArtFocus.file)
        c.logo = file("logo.png")
        c.manual = file("manual.pdf")
        if let a = file("about.json"), let data = try? Data(contentsOf: a) {
            if let about = try? JSONDecoder().decode(LauncherAbout.self, from: data) { c.about = about } else { fputs("[RED] launcher: \(a.lastPathComponent) cannot be read; no About this game\n", stderr) }
        }
        if let f = file("facts.json"), let data = try? Data(contentsOf: f), let facts = try? JSONDecoder().decode(LauncherFacts.self, from: data) { c.facts = facts }
        if let g = guideFolder(environment: environment, bundle: bundle), let found = findGuide(in: g, lang: lang) { c.guide = found.index; c.guideRoot = found.root }
        return c
    }

    // The offline pages' folder, as hle_web.c finds it: DM_HTML, else html beside the RomFS folder when there is one, else the bundle's html. A slim build's game files are Documents/romfs.img
    // with no html beside them, while build_ipa.sh packs the pages into the app; main.m then sets DM_HTML to the app's copy, and this falls back the same way when it has not
    static func guideFolder(environment: [String: String], bundle: Bundle) -> URL? {
        if let h = environment["DM_HTML"], !h.isEmpty { return URL(fileURLWithPath: h) }
        if let r = environment["DM_ROMFS"], !r.isEmpty {
            let beside = URL(fileURLWithPath: r).deletingLastPathComponent().appendingPathComponent("html")
            var d: ObjCBool = false
            if FileManager.default.fileExists(atPath: beside.path, isDirectory: &d), d.boolValue { return beside }
        }
        return bundle.resourceURL?.appendingPathComponent("html")
    }

    // The game's guide in folder: an HtmlDocument's html-document (the folder itself, or one html<n>/html-document per document), whose .htdocs other than the legal ones
    // (important, ipnotices, support) holds html/<LANG>/index.html or html/index.html. The language folder: the game language's (USen for en-US, EUfr for fr and so on), else
    // USen, EUen, else the first. nil when there is none
    static func findGuide(in folder: URL, lang: String?) -> (index: URL, root: URL)? {
        let fm = FileManager.default
        func dirs(_ u: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        var documents: [URL] = []
        let own = folder.appendingPathComponent("html-document")
        if fm.fileExists(atPath: own.path) { documents.append(own) }
        for d in dirs(folder) where d.lastPathComponent.hasPrefix("html") && d.lastPathComponent != "html-document" {
            let doc = d.appendingPathComponent("html-document")
            if fm.fileExists(atPath: doc.path) { documents.append(doc) }
        }
        let legal: Set<String> = ["important.htdocs", "ipnotices.htdocs", "support.htdocs"]
        let wanted = guideLanguages(lang)
        for doc in documents {
            for htdocs in dirs(doc) where htdocs.pathExtension == "htdocs" && !legal.contains(htdocs.lastPathComponent) {
                let html = htdocs.appendingPathComponent("html")
                let langs = dirs(html).filter { fm.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
                if let pick = wanted.lazy.compactMap({ w in langs.first { $0.lastPathComponent.caseInsensitiveCompare(w) == .orderedSame } }).first ?? langs.first {
                    return (pick.appendingPathComponent("index.html"), htdocs)
                }
                for index in [html.appendingPathComponent("index.html"), htdocs.appendingPathComponent("index.html")] where fm.fileExists(atPath: index.path) {
                    return (index, htdocs)
                }
            }
        }
        return nil
    }

    // The guide's language folders to try for a game language (DM_LANG: en-US, en-GB, fr, fr-CA, ja ...), in order, ending with USen and EUen
    static func guideLanguages(_ lang: String?) -> [String] {
        let map: [String: String] = ["en-US": "USen", "en-GB": "EUen", "en": "USen", "ja": "JPja", "fr": "EUfr", "fr-FR": "EUfr", "fr-CA": "USfr", "de": "EUde", "it": "EUit",
                                     "es": "EUes", "es-ES": "EUes", "es-419": "USes", "es-MX": "USes", "nl": "EUnl", "pt": "EUpt", "pt-PT": "EUpt", "pt-BR": "USpt",
                                     "ru": "EUru", "ko": "KRko", "zh-Hans": "CNzh", "zh-CN": "CNzh", "zh-Hant": "TWzh", "zh-TW": "TWzh"]
        var out: [String] = []
        if let l = lang, let m = map[l] ?? map[String(l.prefix { $0 != "-" })] { out.append(m) }
        for d in ["USen", "EUen"] where !out.contains(d) { out.append(d) }
        return out
    }
}

// The art (or, without it, the app icon) and the logo decoded once, with the art's average colour for the tint. It reads the disk and decodes: dm_show_launcher calls it once before the screen shows
struct LauncherArtwork {
    var art: UIImage?
    var icon: UIImage?
    var logo: UIImage?   // decoded and trimmed on the CPU (NX18Logo.decode); nil without dm/logo.png or when it cannot be decoded or shows nothing, and the hero then shows the name
    var logoDark = false   // a black wordmark, drawn with a light glow (NX18Logo.isDark)
    var tint: NX18RGB?
    var wash: UIImage?   // the settings side's backdrop (LauncherBackdrop): the art, or the icon, as a 48 × 27 blurred colour field; made once here, drawn scaled up
    var focus = ArtFocus.centre     // the part of the art the Gate shows (ArtFocus.swift): the player's own framing, else the build's, else the centre
    var packedFocus: ArtFocus?      // the build's (dm/art_focus.json): with one, a framing set back to the centre is kept as the player's choice (LauncherView.endFraming)

    @MainActor static func load(_ content: LauncherContent) -> LauncherArtwork {
        var w = LauncherArtwork()
        if let u = content.art, let img = UIImage(contentsOfFile: u.path) { w.art = img.preparingForDisplay() ?? img }
        else if content.art != nil { fputs("[RED] launcher: dm/art.jpg cannot be decoded; showing the icon\n", stderr) }
        if let u = content.logo {
            if let cg = NX18Logo.decode(u) { w.logo = UIImage(cgImage: cg); w.logoDark = NX18Logo.isDark(cg) } else { fputs("[RED] launcher: dm/logo.png cannot be decoded; showing the name\n", stderr) }
        }
        w.icon = appIcon()
        w.packedFocus = ArtFocus.packed(at: content.artFocus)
        w.focus = ArtFocus.resolve(saved: ArtFocus.saved(), packed: w.packedFocus)
        w.tint = (w.art ?? w.icon)?.cgImage.flatMap(NX18Palette.average)
        w.wash = wash(w.art ?? w.icon)
        return w
    }

    // The art's colours as a tiny blurred field (48 × 27): averaged down by the draw, blurred once on the CPU (NX18Blur), so drawn scaled up it is a soft multi-colour gradient with
    // no detail and no live blur (nothing redraws per frame). Without art or icon: NX 18's teal into coral, as the art side's fallback
    static func wash(_ image: UIImage?) -> UIImage? {
        let w = 48, h = 27
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        if let cg = image?.cgImage {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        } else {
            let c = NX18RGB(hex: NX18Palette.cyanHex), k = NX18RGB(hex: NX18Palette.coralHex)
            let colours = [CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1), CGColor(srgbRed: k.r, green: k.g, blue: k.b, alpha: 1)] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        }
        NX18Blur.blur(ctx)
        return ctx.makeImage().map { UIImage(cgImage: $0) }
    }

    // The app icon: the asset catalog's (build_ipa.sh's AppIcon), else the largest the Info.plist names
    @MainActor static func appIcon() -> UIImage? {
        if let i = UIImage(named: "AppIcon") { return i }
        guard let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any], let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String], let last = files.last else { return nil }
        return UIImage(named: last)
    }
}
