// Mac app launcher: the settings window shown before the game starts, in the launcher's own process (launcher.c calls dm_mac_launcher before it starts the host). Its settings come from the
// app's Resources/dm/launcher.json (dm/games/settings.py with SETTINGS_PLATFORM=mac); the model and the rows are the iOS launcher's (dm/ios/Sources/LauncherSettings.swift, LauncherRow.swift),
// and so is the store: launcher.<VAR> in the app's preferences, which launcher.c reads when the window is not shown (docs/frontends.md, Saved choices). Basic settings (level basic) come
// first, the others under Advanced settings, each in the list's sections (a game without basic rows shows them all, with no Advanced). Play puts the settings into this process's environment,
// which the host inherits; Quit and closing the window end the app without the game. "Show this window at launch" off: no window unless Option is held at launch, and launcher.c applies the
// saved choices. The window never takes focus by itself: an app opened in the background (open -g) keeps its window behind until the player switches to it.
// The look is the NX 18 one the iOS launcher has (LauncherRow.swift's NX18Palette): a dark window, a banner across the top with the game's key art (Resources/dm/art.jpg; without it the app
// icon blurred, with the icon itself on it), the game's logo (Resources/dm/logo.png) or else its name and the status line over it, the coral Play pill, Game guide (the game's own pages under Resources/html in a window of the app's own, MacGuideWindow, or
// Resources/dm/manual.pdf) and About this game (Resources/dm/about.json, a sheet), the cyan-to-coral rails under the banner, the preset chips, cyan section headings and controls on
// charcoal rows. Only the window's background takes a little of the art's colour; the accents, the rails and the mark keep the logo's
import AppKit
import Combine
import CoreHaptics
import GameController
import Metal
import MetalFX
import QuartzCore
import SwiftUI
import WebKit

private func info(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }

/// The host's comparison of the two saves (dm/host/save_sync.c). This launcher links save_sync.o but imports no C header (pack_app.py builds it with swiftc and no bridging
/// header), so the symbol is declared here.
@_silgen_name("save_sync_report")
private func save_sync_report(_ save: UnsafePointer<CChar>, _ title: UnsafePointer<CChar>, _ folder: UnsafePointer<CChar>?, _ waitMs: Int32,
                              _ out: UnsafeMutablePointer<CChar>, _ n: Int) -> Int32

/// Cloud saves before Play: this Mac's save against the cloud's (SaveSyncReport, shared with the iPhone launcher), and the question it needs, as alerts.
/// It runs with the window's Play and, with the window off, before dmMacLauncher returns; DM_LAUNCHER=0 asks nothing (the host takes the newer save).
enum SaveCheck {
    enum Outcome { case play(String?), retry, cancel }

    /// Blocks while the cloud's file comes (SaveSyncReport.waitMs at most): call it off the main thread. nil: no report (sync is then left to the host as before)
    static func report() -> SaveSyncReport? {
        // getenv, not ProcessInfo.environment: launcher.c sets DM_SAVE and applies the env files in this process before the window
        guard let save = getenv("DM_SAVE") else { fputs("launcher: save sync: no DM_SAVE\n", stderr); return nil }
        guard let id = info("DMTitleID"), !id.isEmpty else { fputs("launcher: save sync: no DMTitleID\n", stderr); return nil }
        // the folder as launcher.c will pass it (cloud_saves_folder): DM_SAVE_SYNC from the launch environment or an env file, else the window's choice; "0" = off
        let folder = getenv("DM_SAVE_SYNC").map { String(cString: $0) } ?? (UserDefaults.standard.string(forKey: "cloudSaves.folder") ?? "")
        let line = (folder.isEmpty ? "0" : folder).withCString { f in SaveSyncReport.run { save_sync_report(save, id, f, SaveSyncReport.waitMs, $0, $1) } }
        guard let line else { fputs("launcher: save sync: no report on \(String(cString: save))\n", stderr); return nil }
        fputs("launcher: save sync: \(line)\n", stderr)
        let r = SaveSyncReport(line: line)
        if r?.pullPending == true { fputs("launcher: save sync: \(SaveSyncReport.pullPendingNote)\n", stderr) }
        return r
    }

    /// The question the report needs, as a modal alert; `cancel` names the way back ("Cancel" to the window, "Quit" without one)
    static func ask(_ r: SaveSyncReport?, cancel: String) -> Outcome {
        switch SaveSyncReport.step(r) {
        case .play(let choice): return .play(choice)
        case .choose:
            guard let r else { return .play(nil) }
            let a = NSAlert()
            a.messageText = SaveSyncReport.chooseTitle
            a.informativeText = r.chooseMessage(here: "Mac")
            a.alertStyle = .warning
            a.addButton(withTitle: r.localLabel(here: "Mac"))
            a.addButton(withTitle: r.cloudLabel)
            a.addButton(withTitle: cancel)
            a.buttons[0].keyEquivalent = ""   // no default: Return must not pick a save (the newer is not always the one to keep)
            a.buttons[2].keyEquivalent = "\u{1b}"
            switch a.runModal() {
            case .alertFirstButtonReturn: return .play(r.localChoice)
            case .alertSecondButtonReturn: return .play(r.cloudChoice)
            default: return .cancel
            }
        case .unreadable:
            let a = NSAlert()
            a.messageText = SaveSyncReport.unreadableTitle
            a.informativeText = r?.unreadableMessage(here: "Mac") ?? ""
            a.addButton(withTitle: "Play This Mac's Save")
            a.addButton(withTitle: "Try Again")
            a.addButton(withTitle: cancel)
            a.buttons[2].keyEquivalent = "\u{1b}"
            switch a.runModal() {
            case .alertFirstButtonReturn: return .play("offline")   // the mount does not wait for the cloud again
            case .alertSecondButtonReturn: return .retry
            default: return .cancel
            }
        }
    }

    static func apply(_ choice: String?) {
        guard let choice else { return }
        setenv("DM_SAVE_SYNC_CHOICE", choice, 1)
        fputs("launcher: DM_SAVE_SYNC_CHOICE=\(choice)\n", stderr)
    }

    /// With the window off: the check and its question before the game, the app in front only while it asks. false: the player quit
    static func withoutWindow() -> Bool {
        final class Box: @unchecked Sendable { let lock = NSLock(); var report: SaveSyncReport?; var waiting = false }
        let app = NSApplication.shared
        defer { app.setActivationPolicy(.prohibited) }
        while true {
            let box = Box(), sem = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                let r = report()
                box.lock.lock(); box.report = r; box.lock.unlock()
                sem.signal()
                DispatchQueue.main.async { if box.waiting { app.abortModal() } }   // runs inside the waiting alert's modal loop, if there is one
            }
            if sem.wait(timeout: .now() + 0.5) == .timedOut {   // a cloud file to download: say so, and let the player go on without it
                app.setActivationPolicy(.regular); app.activate(ignoringOtherApps: true)
                let a = NSAlert()
                a.messageText = "Checking the cloud save…"
                a.informativeText = "Waiting for iCloud to deliver this game's save."
                a.addButton(withTitle: "Play Without It")
                a.addButton(withTitle: "Quit")
                box.waiting = true
                let answer = a.runModal()
                box.waiting = false
                if answer == .alertFirstButtonReturn { apply("offline"); return true }
                if answer == .alertSecondButtonReturn { return false }
                sem.wait()   // aborted: the report is in
            }
            box.lock.lock(); let r = box.report; box.lock.unlock()
            if case .play(let choice) = SaveSyncReport.step(r) { apply(choice); return true }
            app.setActivationPolicy(.regular); app.activate(ignoringOtherApps: true)
            switch ask(r, cancel: "Quit") {
            case .play(let choice): apply(choice); return true
            case .retry: continue
            case .cancel: return false
            }
        }
    }
}

// The device facts the rules are decided on (LauncherSettings.swift DeviceFacts): the connected screens' fastest rate (120 fps needs a 120 Hz screen, hle_nvn.c), the
// controllers, MetalFX and GPU capture. The Metal device made here is this launcher
// process's own: the host, started after it, makes its own. No window or screen shape: nothing on the Mac stretches the picture
@MainActor func macDeviceFacts() -> DeviceFacts {
    var f = DeviceFacts()
    f.kind = .mac
    f.hz = NSScreen.screens.map(\.maximumFramesPerSecond).max()
    f.haptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    f.controller = !GCController.controllers().isEmpty
    f.tv = false
    if let dev = MTLCreateSystemDefaultDevice() { f.metalFX = MTLFXSpatialScalerDescriptor.supportsMetal4FX(dev) }   // Metal 4 itself: launcher.c refused a Mac without it (dm_mac_metal4_missing)
    // nvn_mtl.m's capture profile (pso4_capture): Metal's capture layer, which the environment the host inherits loads (MTL_CAPTURE_ENABLED=1 or METAL_CAPTURE_ENABLED=1); asked
    // after the device above is made, as the host asks it after mtl_init
    f.gpuCapture = MTLCaptureManager.shared().supportsDestination(.gpuTraceDocument)
    return f
}

// What the app carries for the window besides launcher.json, each optional and read defensively: the key art, the About text, the manual and the game's own guide pages
struct LauncherExtras {
    // about.json: every field may be missing, empty or of another type (a number, a list); such a field is nil and the others still show, as on iOS (LauncherAbout)
    struct About: Decodable {
        let name, intro, description, publisher, releaseDate, source: String?
        var hasText: Bool { [intro, description, publisher, releaseDate].contains { !($0 ?? "").isEmpty } }
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
            self.init(name: text(.name), intro: text(.intro), description: text(.description), publisher: text(.publisher), releaseDate: text(.releaseDate), source: text(.source))
        }
        enum CodingKeys: String, CodingKey { case name, intro, description, publisher, releaseDate, source }
    }
    var art: NSImage?
    var logo: NSImage?       // dm/logo.png, the game's title wordmark with transparency (scripts/game_art.py), shown in place of the name; nil without it or when it cannot be decoded
    var logoDark = false     // a black wordmark, drawn with a light glow (NX18Logo.isDark)
    var backdrop: NSImage?   // without art: the app icon blurred on the CPU, the banner's backdrop
    var tint: NX18RGB?   // the art's (else the icon's) average colour, for the window's background
    var about: About?
    var manual: URL?
    var guides: [URL] = []   // the folders holding a guide's language folders (…/html<n>/html-document/htmlcontents.htdocs/html), first program first

    // From the app's Resources: dm/art.jpg, dm/logo.png, dm/about.json, dm/manual.pdf, and the guides under html/ (an app of several programs: p<N>/html/ too)
    static func load(resources: URL? = Bundle.main.resourceURL) -> LauncherExtras {
        var x = LauncherExtras()
        guard let res = resources else { return x }
        let fm = FileManager.default
        let dm = res.appendingPathComponent("dm")
        if let img = NSImage(contentsOf: dm.appendingPathComponent("art.jpg")), img.isValid, img.size.width > 0 { x.art = img }
        let logo = dm.appendingPathComponent("logo.png")
        if fm.fileExists(atPath: logo.path) {   // decoded and trimmed on the CPU as on iOS (NX18Logo.decode); one that cannot be decoded or shows nothing leaves the name
            if let cg = NX18Logo.decode(logo) { x.logo = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)); x.logoDark = NX18Logo.isDark(cg) }
            else { fputs("[RED] launcher: dm/logo.png cannot be decoded; showing the name\n", stderr) }
        }
        if let data = try? Data(contentsOf: dm.appendingPathComponent("about.json")) {
            if let a = try? JSONDecoder().decode(About.self, from: data) { if a.hasText { x.about = a } }
            else { fputs("[RED] launcher: dm/about.json cannot be read; no About this game\n", stderr) }
        }
        let pdf = dm.appendingPathComponent("manual.pdf")
        if fm.isReadableFile(atPath: pdf.path) { x.manual = pdf }
        var roots = [res.appendingPathComponent("html")]
        let programs = ((try? fm.contentsOfDirectory(atPath: res.path)) ?? []).compactMap { n -> (Int, URL)? in
            guard n.hasPrefix("p"), let i = Int(n.dropFirst()) else { return nil }
            return (i, res.appendingPathComponent(n).appendingPathComponent("html"))
        }
        roots += programs.sorted { $0.0 < $1.0 }.map(\.1)
        for root in roots {
            for d in numbered(root, prefix: "html") {
                let langs = d.appendingPathComponent("html-document/htmlcontents.htdocs/html")
                if guideIndex(in: langs, language: "en-US") != nil { x.guides.append(langs) }   // folders of legal notices only (important, ipnotices, support.htdocs) have none
            }
        }
        let image = x.art ?? (NSApp?.applicationIconImage)
        if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            x.tint = NX18Palette.average(of: cg)
            if x.art == nil { x.backdrop = blurred(cg, side: 96, radius: 6) }
        }
        return x
    }
    // The icon blurred on the CPU for the backdrop: drawn into a side x side bitmap with Core Graphics, then three passes of a box blur each way (about a Gaussian), so it looks
    // the same whatever draws it later and no Core Image or Metal work is made for it
    private static func blurred(_ image: CGImage, side n: Int, radius r: Int) -> NSImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x21 / 255, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
        ctx.interpolationQuality = .high
        let inset = CGFloat(n) * 0.1   // the icon's rounded corners fall outside, so its edge does not darken the backdrop's
        ctx.draw(image, in: CGRect(x: -inset, y: -inset, width: CGFloat(n) + 2 * inset, height: CGFloat(n) + 2 * inset))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: n * n * 4)
        var a = [Double](repeating: 0, count: n * n * 4), b = a
        for i in 0..<(n * n * 4) { a[i] = Double(px[i]) }
        func pass(_ src: [Double], _ dst: inout [Double], horizontal: Bool) {
            for line in 0..<n {
                for c in 0..<4 {
                    var sum = 0.0
                    func at(_ k: Int) -> Double { let k = Swift.min(Swift.max(k, 0), n - 1); return src[(horizontal ? line * n + k : k * n + line) * 4 + c] }
                    for k in -r...r { sum += at(k) }
                    for k in 0..<n {
                        dst[(horizontal ? line * n + k : k * n + line) * 4 + c] = sum / Double(2 * r + 1)
                        sum += at(k + r + 1) - at(k - r)
                    }
                }
            }
        }
        for _ in 0..<3 { pass(a, &b, horizontal: true); pass(b, &a, horizontal: false) }
        for i in 0..<(n * n * 4) { px[i] = UInt8(Swift.min(255, Swift.max(0, a[i].rounded()))) }
        return ctx.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: n, height: n)) }
    }
    // A folder's subfolders <prefix><n> in number order
    private static func numbered(_ dir: URL, prefix: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { n -> (Int, String)? in
            guard n.hasPrefix(prefix), let i = Int(n.dropFirst(prefix.count)) else { return nil }
            return (i, n)
        }.sorted { $0.0 < $1.0 }.map { dir.appendingPathComponent($0.1) }
    }
    // The guide's folder names for a game language (DM_LANG's values, dm/tools/nacp.py LANGUAGES), the Switch's region and language codes, then USen and EUen
    static func guideFolders(_ language: String) -> [String] {
        let map = ["en-US": "USen", "en-GB": "EUen", "ja": "JPja", "fr": "EUfr", "de": "EUde", "es-419": "USes", "es": "EUes", "it": "EUit", "nl": "EUnl", "fr-CA": "USfr",
                   "pt": "EUpt", "pt-BR": "USpt", "ru": "EUru", "ko": "KRko", "zh-Hant": "TWzh", "zh-Hans": "CNzh"]
        let base = String(language.split(separator: "-").first ?? "")
        let byBase = ["en": "USen", "ja": "JPja", "fr": "EUfr", "de": "EUde", "es": "EUes", "it": "EUit", "nl": "EUnl", "pt": "EUpt", "ru": "EUru", "ko": "KRko", "zh": "CNzh"]
        var out: [String] = []
        for f in [map[language], byBase[base], "USen", "EUen"] { if let f, !out.contains(f) { out.append(f) } }
        return out
    }
    // A guide's index.html in the language's folder, else USen, EUen, the first language folder with one, else html/index.html
    static func guideIndex(in langs: URL, language: String) -> URL? {
        let fm = FileManager.default
        for f in guideFolders(language) {
            let u = langs.appendingPathComponent(f).appendingPathComponent("index.html")
            if fm.isReadableFile(atPath: u.path) { return u }
        }
        let names = ((try? fm.contentsOfDirectory(atPath: langs.path)) ?? []).sorted()
        for n in names {
            let u = langs.appendingPathComponent(n).appendingPathComponent("index.html")
            if fm.isReadableFile(atPath: u.path) { return u }
        }
        let flat = langs.appendingPathComponent("index.html")
        return fm.isReadableFile(atPath: flat.path) ? flat : nil
    }
    var hasGuide: Bool { !guides.isEmpty }
    // The first guide's page in the game's language
    func guide(language: String) -> URL? { guidePage(language: language)?.index }
    // That page and the folder its scripts may read (the guide's .htdocs, which holds the language folders' html/)
    func guidePage(language: String) -> (index: URL, root: URL)? {
        guides.lazy.compactMap { langs in LauncherExtras.guideIndex(in: langs, language: language).map { ($0, langs.deletingLastPathComponent()) } }.first
    }
}

struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let done: (Bool) -> Void
    let fit: (CGFloat) -> Void
    let extras: LauncherExtras
    @AppStorage("window.show") private var show = true
    @AppStorage("window.advanced") private var advanced = false
    @AppStorage("cloudSaves.folder") private var cloudFolder = ""
    @State private var lastPlayed: Date?
    @State private var aboutShown = false
    @State private var bannerWidth: CGFloat = 600   // the banner's width, which bounds the logo's
    @State private var checking = false
    @State private var check = 0   // which Play the running check is for: one the player went on from without it is dropped
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(m: LauncherModel, done: @escaping (Bool) -> Void, fit: @escaping (CGFloat) -> Void, extras: LauncherExtras = .load()) {
        self.m = m; self.done = done; self.fit = fit; self.extras = extras
    }

    private var name: String { info("CFBundleName") ?? "Game" }
    private var background: Color { NX18Palette.background(tint: extras.tint) }
    private var presetNote: String {
        switch m.activePreset {
        case .battery?: return "Lower frame rate and resolution, for a cooler Mac"
        case .balanced?: return "The settings this game was tested with"
        case .quality?: return "Full resolution and MetalFX upscaling"
        case nil: return "Your own choices"
        }
    }
    private var status: LauncherStatus {
        var s = LauncherStatus()
        s.lastPlayed = lastPlayed
        s.cloud = CloudSavesSection.fixed.map { $0.isEmpty ? .off : .on } ?? (cloudFolder.isEmpty ? .off : .on)
        s.console = m.console.flatMap(LauncherStatus.Console.init(rawValue:))
        return s
    }

    var body: some View {
        VStack(spacing: 0) {
            banner
            NX18Rails(axis: .horizontal, flowing: true)   // the colours drift slowly along it (still under Reduce Motion; LauncherRow.swift)
            Form {
                if m.hasPresets {
                    Section {
                        LabeledContent {
                            PresetChips(m: m)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Preset")
                                Text(presetNote).nxFont(.footnote).foregroundStyle(NX18Palette.muted)
                            }
                        }
                    }
                    .listRowBackground(NX18Palette.row)
                }
                settingSections(basic: true)
                CloudSavesSection()
                if !m.hasBasicRows {
                    resetSection
                } else {
                    Section {
                        DisclosureGroup("Advanced settings", isExpanded: $advanced) {}
                    }
                    .listRowBackground(NX18Palette.row)
                    if advanced {
                        settingSections(basic: false)
                        resetSection
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentSize.height + $0.contentInsets.top + $0.contentInsets.bottom - $0.containerSize.height
            } action: { _, extraHeight in
                fit(extraHeight)
            }
            NX18Palette.separator.frame(height: 1)
            HStack {
                Toggle("Show this window at launch", isOn: $show).toggleStyle(.checkbox)
                Spacer()
                if checking {
                    ProgressView().controlSize(.small)
                    Text("Checking the cloud save…").foregroundStyle(NX18Palette.muted)
                    Button("Play Without It") { checking = false; SaveCheck.apply("offline"); done(true) }.nxPushButton()
                }
                Button("Quit") { done(false) }.nxPushButton()
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(NX18Palette.card(tint: extras.tint))
        }
        .background(background)
        .ignoresSafeArea(.container, edges: .top)   // the banner runs under the transparent title bar
        .nxTextRoot()   // NX 18's UI font for every text below that names no style (NXFont.swift)
        .tint(NX18Palette.cyan)
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 520, idealWidth: 600)
        .sheet(isPresented: $aboutShown) {
            if let a = extras.about { AboutGameSheet(about: a, name: name, art: extras.art, tint: extras.tint) }
        }
        .task {
            let folder = Self.saveFolder
            lastPlayed = await Task.detached(priority: .utility) { folder.flatMap { LauncherStatus.lastModified(under: $0) } }.value
        }
    }

    // The banner: the key art (or the blurred icon with the icon on it), faded into the window at the bottom, the mark, the logo (else the name), the status line and the buttons
    private var banner: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .overlay {
                    if let art = extras.art {
                        Image(nsImage: art).resizable().scaledToFill()
                    } else {
                        Image(nsImage: extras.backdrop ?? NSApp.applicationIconImage).resizable().interpolation(.high).scaledToFill().opacity(0.8)
                    }
                }
                .clipped()
                .overlay {
                    LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .black.opacity(0), location: 0.3),
                                           .init(color: background.opacity(0), location: 0.4), .init(color: background.opacity(0.94), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .overlay {
                    LinearGradient(stops: [.init(color: background.opacity(0.55), location: 0), .init(color: background.opacity(0), location: 0.65)],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .accessibilityHidden(true)
                .gesture(WindowDragGesture())
            if extras.art == nil {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 28).padding(.top, 26)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            VStack(alignment: .leading, spacing: 6) {
                // the game's logo in place of its name when the app has one: at most 72 pt tall and 60 % of the banner's width; VoiceOver still reads the name
                if let logo = extras.logo {
                    NX18GameLogo(image: Image(nsImage: logo), natural: logo.size, name: name, dark: extras.logoDark, maxWidth: bannerWidth * 0.6, maxHeight: 72)
                } else {
                    Text(name).nxFont(size: 28, weight: .bold).foregroundStyle(.white).lineLimit(2)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
                        .accessibilityAddTraits(.isHeader)
                }
                statusLine
                // Play and the buttons the app has on one line: their full names when they fit, else short ones, else icons only (each still named for VoiceOver and the tooltip)
                ViewThatFits(in: .horizontal) {
                    buttons(.full)
                    buttons(.short)
                    buttons(.icon)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 24).padding(.bottom, 20)
        }
        .frame(height: 248)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { bannerWidth = $0 }
        .overlay(alignment: .topTrailing) {
            NX18Mark(height: 20)
                .background { if extras.art != nil { NX18MarkShade(strong: reduceTransparency) } }   // over key art: the banner's top shade alone leaves it on a light grey (LauncherRow.swift)
                .padding(.top, 12).padding(.trailing, 16).allowsHitTesting(false)
        }
        .clipped()
    }

    /// Play, once the cloud's save is compared with this Mac's: a save that changed on both sides is the player's pick, not the newer file's (SaveCheck)
    private func start() {
        check += 1; checking = true
        let mine = check
        DispatchQueue.global(qos: .userInitiated).async {
            let r = SaveCheck.report()
            DispatchQueue.main.async {
                guard checking, check == mine else { return }   // the player played without it
                checking = false
                switch SaveCheck.ask(r, cancel: "Cancel") {
                case .play(let choice): SaveCheck.apply(choice); done(true)
                case .retry: start()
                case .cancel: break   // back to the window, nothing chosen
                }
            }
        }
    }

    private enum PillLabel { case full, short, icon }
    private func buttons(_ l: PillLabel) -> some View {
        HStack(spacing: 10) {
            Button { start() } label: {
                Label("Play", systemImage: "play.fill").labelStyle(PlayLabel())
            }
            .buttonStyle(NX18PillStyle(fill: NX18Palette.coral, text: NX18Palette.charcoal, font: NXFont.fixed(16, weight: .bold), height: 38))
            .keyboardShortcut(.defaultAction)
            .disabled(checking)
            .accessibilityLabel("Play")
            .accessibilityHint("Starts the game with these settings")
            if extras.hasGuide {
                pill("Game guide", short: "Guide", icon: "book", label: l, help: "Opens the game's own guide in a window") { openGuide() }
            }
            if let manual = extras.manual {
                pill(extras.hasGuide ? "Manual" : "Game guide", short: extras.hasGuide ? "Manual" : "Guide", icon: "doc.richtext", label: l, help: "Opens the game's manual (PDF)") {
                    NSWorkspace.shared.open(manual)
                }
            }
            if extras.about != nil {
                pill("About this game", short: "About", icon: "info.circle", label: l, help: "The game's description, publisher and release date") { aboutShown = true }
            }
        }
        .fixedSize()
    }
    private func pill(_ title: String, short: String, icon: String, label l: PillLabel, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            switch l {
            case .full: Label(title, systemImage: icon)
            case .short: Label(short, systemImage: icon)
            case .icon: Image(systemName: icon)
            }
        }
        .buttonStyle(NX18PillStyle())
        .help(l == .full ? help : "\(title): \(help.prefix(1).lowercased() + help.dropFirst())")
        .accessibilityLabel(title)
    }

    private var statusLine: some View {
        let s = status
        return HStack(spacing: 0) {
            Text("Version \(info("CFBundleShortVersionString") ?? "1.0")")
            if !s.parts().isEmpty {
                Text(verbatim: "  ·  ").accessibilityHidden(true)
                LauncherStatusLine(status: s, color: NX18Palette.onArt)
            }
        }
        .nxFont(.footnote)
        .foregroundStyle(NX18Palette.onArt)   // the muted grey a little lighter, as it sits on the art
        .lineLimit(1)
    }

    // The basic rows' sections, or those under Advanced. Each section is keyed by its part as well as its title: both parts can have a section of the same name (Game), and the
    // grouped Form mixed up the two parts' rows and boxes when two of its sections shared an identity
    @ViewBuilder private func settingSections(basic: Bool) -> some View {
        ForEach(m.groups(basic: basic).map { (key: (basic ? "basic/" : "advanced/") + $0.section, group: $0) }, id: \.key) { item in
            let g = item.group
            Section {
                ForEach(g.rows) { SettingRow(s: $0, m: m) }
            } header: {
                NX18SectionHeader(g.section)
            }
            .listRowBackground(NX18Palette.row)
            .listRowSeparatorTint(NX18Palette.separator)
        }
    }

    private var resetSection: some View {
        Section {
            Button { m.reset() } label: {
                Text("Reset to tested defaults").foregroundStyle(m.changed ? NX18Palette.coral : NX18Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!m.changed)
        } footer: {
            Text("Brings back all settings this game was tested with.").nxFontIfCustom(.footnote).foregroundStyle(NX18Palette.muted)
        }
        .listRowBackground(NX18Palette.row)
    }

    // The guide in the game language the window shows (Game language, else the app's DMLanguage), in the guide window (MacGuideWindow), not a browser: one opening the pages from
    // file: URLs refuses their scripts' reads of the guide's other files and has no window.nx
    private func openGuide() {
        let lang = m.values["DM_LANG"] ?? info("DMLanguage") ?? "en-US"
        guard let page = extras.guidePage(language: lang) else { return }
        MacGuideWindow.show(index: page.index, root: page.root, fontDir: Bundle.main.resourceURL?.appendingPathComponent("dm/font"), title: name)
        fputs("launcher: game guide \(page.index.path)\n", stderr)
    }

    // Where the host keeps the save (launcher.c: DM_SAVE, else Application Support/nxnative/<title ID>/save), for Last played
    static var saveFolder: URL? {
        if let s = ProcessInfo.processInfo.environment["DM_SAVE"], !s.isEmpty { return URL(fileURLWithPath: s) }
        guard let id = info("DMTitleID"), !id.isEmpty else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/nxnative/\(id)/save")
    }
}

// Play's label: the triangle and the word, the triangle a little smaller
private struct PlayLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) { configuration.icon.font(.system(size: 13, weight: .bold)); configuration.title }   // system: symbol
    }
}

// Game guide: the game's own pages in a window of the app's own, in a WKWebView configured as the iPhone's guide viewer is (LauncherGuideFiles.swift: the guide's .htdocs served
// through nx18guide://, the window.nx shim, a Content-Security-Policy and a block list that keep the pages off the network, links outside the guide refused). The default browser,
// which the window used before, opens the pages from file: URLs: there their scripts' XMLHttpRequest and fetch of the guide's other files are refused, and window.nx, the Switch
// applet's API they call, does not exist. The page is laid out at the console's 1280x720 and zoomed to fit the window, whole (MacGuideBox; the window keeps 16:9 as it is resized).
// The title bar has Back (the page's own Back when it assigned one, else the previous page) and the page's L / R page turning when it assigned them; a two-finger swipe goes back
// through the pages too. nx.endApplet, window.close and the console's end URL (http://localhost/) close the window; Game guide again brings it forward. Play and Quit close it with
// the settings window
@MainActor final class MacGuideWindow: NSObject, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    private(set) static var current: MacGuideWindow?
    let files: LauncherGuideFiles
    private(set) var web: WKWebView!
    let box = MacGuideBox()
    private(set) var window: NSWindow?
    private(set) var index: URL?
    private(set) var footer: Set<String> = []   // the page's nx.footer buttons
    private var buttons: [String: NSButton] = [:]   // the title bar's Back, L and R
    private var history: NSKeyValueObservation?
    var closed: (() -> Void)?   // after the page or the window closed it

    // The guide's web view, not yet in a window (show puts it in one; dm/ios/tests/mac_guide_check.swift loads pages into it directly)
    init(root: URL, fontDir: URL?) {
        files = LauncherGuideFiles(root: root, fontDir: fontDir)
        super.init()
        web = WKWebView(frame: NSRect(origin: .zero, size: LauncherGuideFiles.pageSize), configuration: LauncherGuideFiles.configuration(files: files, handler: self))
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.underPageBackgroundColor = .black
        web.setAccessibilityLabel("Game guide")
        box.frame = NSRect(x: 0, y: 0, width: 1120, height: 630)
        box.web = web
        history = web.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.refresh() } }
    }
    // Loads a page of the guide; false for one outside its folder
    @discardableResult func open(_ page: URL) -> Bool {
        guard let start = files.url(for: page) else { fputs("[RED] launcher: the guide's index.html is not inside its folder\n", stderr); return false }
        index = page
        LauncherGuideFiles.load(web, start: start)
        return true
    }
    // The guide window, made once: the same page again only comes forward; another language's page replaces it
    static func show(index: URL, root: URL, fontDir: URL?, title: String) {
        if let c = current, let w = c.window, c.files.root == root.standardizedFileURL.resolvingSymlinksInPath() {
            if c.index != index { c.open(index) }
            w.makeKeyAndOrderFront(nil); return
        }
        current?.close()
        let g = MacGuideWindow(root: root, fontDir: fontDir)
        guard g.open(index) else { g.close(); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 630), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "\(title): Game guide"; w.isReleasedWhenClosed = false; w.delegate = g
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(NX18Palette.background)
        w.contentMinSize = NSSize(width: 640, height: 360)
        w.contentAspectRatio = LauncherGuideFiles.pageSize   // the page fills the window; full screen letterboxes it (MacGuideBox)
        w.contentView = g.box
        w.addTitlebarAccessoryViewController(g.titleButtons())
        w.center()
        g.window = w; current = g
        g.refresh()
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(g.web)   // the arrow keys reach the page's own key handlers
    }
    // Back, L and R in the title bar, at its trailing end
    private func titleButtons() -> NSTitlebarAccessoryViewController {
        func button(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: self, action: action)
            b.bezelStyle = .texturedRounded; b.toolTip = label; b.setAccessibilityLabel(label)
            return b
        }
        buttons = ["B": button("chevron.backward", "Back", #selector(pressBack)), "L": button("chevron.left", "Previous page (L)", #selector(pressL)),
                   "R": button("chevron.right", "Next page (R)", #selector(pressR))]
        buttons["B"]?.keyEquivalent = "["; buttons["B"]?.keyEquivalentModifierMask = .command
        let stack = NSStackView(views: [buttons["B"], buttons["L"], buttons["R"]].compactMap { $0 })
        stack.spacing = 6; stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
        let c = NSTitlebarAccessoryViewController()
        c.view = stack; c.layoutAttribute = .trailing
        return c
    }
    @objc private func pressBack() { press("B") }
    @objc private func pressL() { press("L") }
    @objc private func pressR() { press("R") }
    // A footer button on the page: its own when it assigned it; B left to the window goes to the previous page, else closes the window
    func press(_ button: String) {
        web.evaluateJavaScript(LauncherGuideFiles.footerScript(button)) { [weak self] r, _ in
            MainActor.assumeIsolated {
                guard let self, button == "B", (r as? String) ?? "back" == "back" else { return }
                if self.web.canGoBack { self.web.goBack() } else { self.close() }
            }
        }
    }
    private func refresh() {
        buttons["B"]?.isHidden = !(web.canGoBack || footer.contains("B"))
        buttons["L"]?.isHidden = !(footer.contains("L") || footer.contains("R")); buttons["L"]?.isEnabled = footer.contains("L")
        buttons["R"]?.isHidden = !(footer.contains("L") || footer.contains("R")); buttons["R"]?.isEnabled = footer.contains("R")
    }
    // Closes the window, if any, and lets the page go (the content controller held this object as its message handler)
    func close() {
        LauncherGuideFiles.detach(web)
        web.navigationDelegate = nil
        web.stopLoading()
        history = nil
        if let w = window { window = nil; w.delegate = nil; w.orderOut(nil); w.close() }
        if Self.current === self { Self.current = nil }
        let done = closed; closed = nil; done?()
    }
    func windowWillClose(_ n: Notification) { window?.delegate = nil; window = nil; close() }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "nx18State" {
            if message.frameInfo.isMainFrame { footer = LauncherGuideFiles.footer(of: message.body); refresh() }
            return
        }
        close()   // nx.endApplet, nx.exit, window.close
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        switch LauncherGuideFiles.navigation(action.request.url) {
        case .allow: return .allow
        case .refuse: return .cancel
        case .end: close(); return .cancel
        }
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { footer = []; refresh() }   // a new page: it assigns its own
}

// The guide window's content: the page at the console's 1280x720 zoomed to fit, whole and centred (the rest in the window's background), as the in-game viewer does on the Mac
// (dm/host/web_apple.m -place)
final class MacGuideBox: NSView {
    var web: WKWebView? {
        didSet { oldValue?.removeFromSuperview(); if let web { addSubview(web); place() } }
    }
    override var isFlipped: Bool { true }
    // The page's rect in the box
    var pageFrame: CGRect { LauncherGuideFiles.fit(in: bounds) }
    func place() {
        guard let web else { return }
        let r = pageFrame
        guard r.width >= 1 else { return }
        // Whole points (WebKit takes the viewport from the frame's whole points): the width's zoom, and the height rounded up so the viewport is not a line short of 720
        let w = r.width.rounded(.down), zoom = w / LauncherGuideFiles.pageSize.width, h = (LauncherGuideFiles.pageSize.height * zoom).rounded(.up)
        web.frame = NSRect(x: ((bounds.width - w) / 2).rounded(.down), y: ((bounds.height - h) / 2).rounded(.down), width: w, height: h)
        web.pageZoom = zoom   // the page's viewport stays 1280x720
    }
    override func resizeSubviews(withOldSize s: NSSize) { super.resizeSubviews(withOldSize: s); place() }
    override func layout() { super.layout(); place() }
}

// A capsule button on the banner: the coral Play pill, or a quiet one (white on a translucent dark fill) for the guide and About
struct NX18PillStyle: ButtonStyle {
    var fill: Color = Color.white.opacity(0.14)
    var text: Color = .white
    var font: Font = NXFont.fixed(13, weight: .semibold)
    var height: CGFloat = 30
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font).foregroundStyle(text).lineLimit(1)
            .padding(.horizontal, height * 0.55)
            .frame(height: height)
            .background(Capsule().fill(fill))
            .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.18 : 0)))
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.5)
    }
}

// A push button (Quit, Done, the Cloud saves buttons) with the UI font: AppKit draws a bordered button's title in the system font whatever the view's font, so with the UI font it is
// a pill of the banner's look instead (primary: the default button, cyan); without it the bordered button, as before
private struct NXPushButton: ViewModifier {
    let primary: Bool
    func body(content: Content) -> some View {
        if NXFont.name != nil {
            content.buttonStyle(NX18PillStyle(fill: primary ? NX18Palette.cyan : Color.white.opacity(0.14), text: primary ? NX18Palette.charcoal : .white, height: 26))
        } else {
            content
        }
    }
}
extension View {
    func nxPushButton(primary: Bool = false) -> some View { modifier(NXPushButton(primary: primary)) }
}

// About this game (dm/about.json, titledb's text): the art, the name, the intro and description, the publisher and release date, and where the text came from
struct AboutGameSheet: View {
    let about: LauncherExtras.About
    let name: String
    let art: NSImage?
    let tint: NX18RGB?
    @Environment(\.dismiss) private var dismiss

    private var released: String? {
        guard let s = about.releaseDate, !s.isEmpty else { return nil }
        let p = DateFormatter(); p.calendar = Calendar(identifier: .gregorian); p.locale = Locale(identifier: "en_US_POSIX"); p.timeZone = TimeZone(identifier: "UTC"); p.dateFormat = "yyyy-MM-dd"
        guard let d = p.date(from: s) else { return s }
        let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .none; f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }
    private func fact(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).foregroundStyle(NX18Palette.muted)
            Text(value).foregroundStyle(.white)
        }
        .accessibilityElement(children: .combine)
    }
    private func text(_ s: String?) -> String? { s.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }

    var body: some View {
        let bg = NX18Palette.background(tint: tint)
        VStack(spacing: 0) {
            if let art {
                Color.clear.frame(height: 150)
                    .overlay { Image(nsImage: art).resizable().scaledToFill() }
                    .clipped()
                    .overlay { LinearGradient(colors: [bg.opacity(0), bg], startPoint: .center, endPoint: .bottom) }
                    .accessibilityHidden(true)
            }
            NX18Rails(axis: .horizontal)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(text(about.name) ?? name).nxFont(.title2, weight: .bold).foregroundStyle(.white).accessibilityAddTraits(.isHeader)
                    if let intro = text(about.intro) { Text(intro).nxFont(.headline).foregroundStyle(.white) }
                    if let d = text(about.description) { Text(d).foregroundStyle(Color(nx18: 0xDADADF)).fixedSize(horizontal: false, vertical: true) }
                    if text(about.publisher) != nil || released != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            if let p = text(about.publisher) { fact("Publisher", p) }
                            if let r = released { fact("Released", r) }
                        }
                        .nxFont(.callout)
                        .padding(.top, 4)
                    }
                    if let src = text(about.source) {
                        Text("From \(src)").nxFont(.footnote).foregroundStyle(NX18Palette.muted)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            NX18Palette.separator.frame(height: 1)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).nxPushButton(primary: true)
            }
            .padding(14)
        }
        .frame(width: 520, height: 560)
        .background(bg)
        .nxTextRoot()
        .tint(NX18Palette.cyan)
        .environment(\.colorScheme, .dark)
    }
}

/// Cloud saves: a folder the save is synced through (dm/host/save_sync.h), the one the iPhone app picks in its launcher's Cloud saves section. It is kept in this app's
/// preferences as cloudSaves.folder, which launcher.c puts into DM_SAVE_SYNC before the host starts; a DM_SAVE_SYNC an env file or the launch environment set wins, and is shown here.
struct CloudSavesSection: View {
    @AppStorage("cloudSaves.folder") private var folder = ""
    // DM_SAVE_SYNC as an env file or the launch environment set it; nil when neither did
    static let fixed: String? = {
        let env = ProcessInfo.processInfo.environment
        let keys = ((env["DM_ENV_FILE_KEYS"] ?? "") + " " + (env["DM_ENV_LAUNCH_KEYS"] ?? "")).split(separator: " ")
        return keys.contains("DM_SAVE_SYNC") || env["DM_SAVE_SYNC"] != nil ? env["DM_SAVE_SYNC"] : nil
    }()
    private var fixed: String? { Self.fixed }

    var body: some View {
        Section {
            LabeledContent("Cloud saves") {
                Text(fixed.map { "\(Self.shown($0)) (env.txt)" } ?? (folder.isEmpty ? "Off" : Self.shown(folder)))
                    .foregroundStyle(NX18Palette.muted).lineLimit(1).truncationMode(.head)
            }
            if fixed == nil {
                HStack {
                    Button(folder.isEmpty ? "Choose a folder…" : "Choose a different folder…", action: choose).nxPushButton()
                    if !folder.isEmpty { Button("Turn off") { folder = "" }.nxPushButton() }
                }
            }
        } header: {
            NX18SectionHeader("Cloud saves")
        } footer: {
            Text("Choose the iCloud Drive folder the iPhone or iPad app uses for this game. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in save-backups.")
                .nxFontIfCustom(.footnote)
                .foregroundStyle(NX18Palette.muted)
        }
        .listRowBackground(NX18Palette.row)
        .listRowSeparatorTint(NX18Palette.separator)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = "Use for Cloud Saves"
        panel.message = "The folder the iPhone or iPad app chose in its launcher's Cloud saves"
        panel.directoryURL = URL(fileURLWithPath: folder.isEmpty ? Self.drive : folder)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    static let drive = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"   // iCloud Drive, as the Finder shows it

    /// A path under iCloud Drive as the Finder and the Files app name it: iCloud Drive › Documents › dev › Zelda; any other path as it is
    static func shown(_ path: String) -> String {
        guard path == drive || path.hasPrefix(drive + "/") else { return path }
        return (["iCloud Drive"] + path.dropFirst(drive.count).split(separator: "/").map(String.init)).joined(separator: " › ")
    }
}

private final class Launcher: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: LauncherModel
    var window: NSWindow?
    var play = false

    init(_ model: LauncherModel) { self.model = model }

    func applicationDidFinishLaunching(_ n: Notification) {
        let name = info("CFBundleName") ?? "Game"
        let menu = NSMenu(), item = NSMenuItem(), app = NSMenu()
        app.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = app; menu.addItem(item); NSApp.mainMenu = menu
        let extras = LauncherExtras.load()
        // the banner runs under a transparent title bar (the traffic lights over the art); a dark window whatever the system's appearance, as the iPhone's screen is
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = name; w.isReleasedWhenClosed = false; w.delegate = self
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(NX18Palette.background(tint: extras.tint))
        w.contentMinSize = NSSize(width: 520, height: 0)
        window = w
        if let screen = w.screen ?? NSScreen.main {
            w.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.midX - w.frame.width / 2, y: screen.visibleFrame.maxY))
        }
        let host = NSHostingView(rootView: LauncherView(m: model, done: { [weak self] in self?.finish($0) }, fit: { [weak self] in self?.fit($0) }, extras: extras))
        host.sizingOptions = []   // the Form's measured scroll content owns the height, including after collapse
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        fputs("launcher: art \(extras.art == nil ? "none (the icon)" : "dm/art.jpg"), logo \(extras.logo == nil ? "no" : "yes"), guide \(extras.hasGuide ? "yes" : "no"), manual \(extras.manual == nil ? "no" : "yes"), about \(extras.about == nil ? "no" : "yes")\n", stderr)
        // no activation and no ordering in front of another app's windows: LaunchServices activates an app opened from Finder or the Dock (applicationDidBecomeActive), open -g does not
        if NSApp.isActive { w.makeKeyAndOrderFront(nil) } else { w.orderBack(nil) }
    }
    func applicationDidBecomeActive(_ n: Notification) { window?.makeKeyAndOrderFront(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {   // ⌘Q, or a logout or restart: the app ends without the game (exit 0, as Quit)
        fputs("launcher: quit without starting the game\n", stderr)
        return .terminateNow   // not terminateCancel, which a logout or restart takes as a refusal and stops
    }
    func windowWillClose(_ n: Notification) { finish(false) }

    func fit(_ extraHeight: CGFloat) {
        guard let w = window, let screen = w.screen else { return }
        let frame = LauncherWindowLayout.fitted(w.frame, extraHeight: extraHeight, visible: screen.visibleFrame)
        if abs(frame.height - w.frame.height) > 0.5 { w.setFrame(frame, display: true) }
    }

    func finish(_ play: Bool) {
        guard let w = window else { return }
        window = nil; self.play = play
        // The main thread blocks in launcher.c's waitpid once run() returns, so the window must leave the screen now: no fade-out (it runs on later run-loop passes),
        // and dmMacLauncher flushes the order-out (AppKit commits it at the end of a pass). Without both, the window stayed on screen, not responding, until the game ended
        w.animationBehavior = .none
        if let sheet = w.attachedSheet { w.endSheet(sheet) }   // About this game, if open
        MainActor.assumeIsolated { MacGuideWindow.current?.close() }   // the guide window, if open (finish runs on the main thread: the window's buttons and its delegate)
        w.delegate = nil; w.orderOut(nil)
        NSApp.stop(nil)
        NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)   // run returns at the next event
    }
}

enum LauncherWindowLayout {
    static func fitted(_ frame: NSRect, extraHeight: CGFloat, visible: NSRect) -> NSRect {
        let top = min(frame.maxY, visible.maxY)
        let height = min(frame.height + extraHeight, top - visible.minY)
        return NSRect(x: frame.minX, y: top - height, width: frame.width, height: height)
    }
}

// Why this Mac cannot run the game: its GPU has no Metal 4, the only way the host draws (Metal 4 command queues and MTL4Compiler pipelines; mtl_init stops without it). A virtual Mac's
// paravirtualized GPU is one. launcher.c shows it in an alert and ends before the settings window or the host, window or not. NULL on a supported Mac; the string is the caller's to free.
// assumeMissing (launcher.c's DM_TEST_METAL4=0): the message whatever the GPU, for the test of the refusal
@_cdecl("dm_mac_metal4_missing")
public func dmMacMetal4Missing(_ assumeMissing: Int32) -> UnsafeMutablePointer<CChar>? {
    let dev = MTLCreateSystemDefaultDevice()
    if assumeMissing == 0, let dev, dev.supportsFamily(.metal4) { return nil }
    return strdup("This Mac's GPU (\(dev?.name ?? "no Metal device")) does not support Metal 4, which the game is drawn with. It needs a Mac with Apple silicon on macOS 27.3 or later; a virtual Mac's GPU does not have it.")
}

// Saved choices this build retired (LauncherModel.forgetRetired), forgotten before the saved choices are read: launcher.c calls it, with the window or without
@_cdecl("dm_mac_forget_retired")
public func dmMacForgetRetired() { LauncherModel.forgetRetired(.standard) }

// 1: Play (the window's settings are in the environment), 0: the player quit, 2: no window (no launcher.json, or "Show this window at launch" off): launcher.c applies the saved choices
@_cdecl("dm_mac_launcher")
public func dmMacLauncher() -> Int32 {
    MainActor.assumeIsolated {   // launcher.c calls it on the main thread, before the host starts; LauncherModel is main-actor state (dm/ios/Sources/LauncherSettings.swift)
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json"), let data = try? Data(contentsOf: url) else { return 2 }
        guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return 2 }
        if (UserDefaults.standard.object(forKey: "window.show") as? Bool) == false && !NSEvent.modifierFlags.contains(.option) {
            fputs("launcher: settings window off (hold Option at launch to show it)\n", stderr)
            return SaveCheck.withoutWindow() ? 2 : 0
        }
        let model = LauncherModel(file.settings)
        model.console = file.console
        model.follow(macDeviceFacts, on: [.GCControllerDidConnect, .GCControllerDidDisconnect, NSApplication.didChangeScreenParametersNotification])
        let app = NSApplication.shared, launcher = Launcher(model)
        app.setActivationPolicy(.regular)
        app.delegate = launcher
        fputs("launcher: \(file.settings.count) settings shown\n", stderr)
        app.run()
        CATransaction.flush()   // finish's order-out
        app.setActivationPolicy(.prohibited)   // the host is the game's app from here on
        guard launcher.play else { fputs("launcher: quit without starting the game\n", stderr); return 0 }
        model.apply()
        return 1
    }
}
