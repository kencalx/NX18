// The first-start acknowledgement (NX18-X2.0 gate-ui.md §21.2a, G16): once per game app, before the game's first start, one plain line and I understand. No scrolling legal
// text, no checkbox, no link; a plain statement, not terms. It shows whether or not the Gate does: dmShowLauncher (Launcher.swift) puts it before every path, the Gate's and
// every skipped start's, and runs that path after the press. Stored as nx18.ack in the app's defaults ("1 2026-11-16": the line's version, then the day); not a launcher.* key,
// so Reset all settings keeps it (GW23). Quitting before the press stores nothing: it asks again next time.
// DM_TEST_ACK (GW33), from the launch environment only (an env.txt's is ignored: DM_ENV_FILE_KEYS lists it): 1 shows it whatever nx18.ack says, 0 skips it (tests, A/B).
// The welcome's three choices (Connect to my NX 18 folder, Create a profile, Not now, §21.2) follow below (NX18WelcomeView), on the first Gate; this panel shows before
// them when it is due (one screen each, in that order).
// Look: the look's Gate set (it follows the Appearance choice), over the key art held dark with the hero's scrim; I understand takes the chosen-chip fill (dark: no edge; light:
// a 1.5 pt rosewood edge inside it). Touch, a controller's A, Return or Space
import SwiftUI
import UIKit

enum NX18Acknowledge {
    static let key = "nx18.ack"
    static let version = 1
    static let line = "You built this app yourself, from your own legally owned and acquired game and keys. It's for your own use only; please don't share it."

    // Whether the panel is due before this start
    static func due(environment: [String: String] = ProcessInfo.processInfo.environment, defaults: UserDefaults = .standard) -> Bool {
        let fromFile = Set((environment["DM_ENV_FILE_KEYS"] ?? "").split(separator: " ").map(String.init))
        if let t = environment["DM_TEST_ACK"], !fromFile.contains("DM_TEST_ACK") {
            if t == "1" { return true }
            if t == "0" { return false }
        }
        guard let v = defaults.string(forKey: key), let n = Int(v.split(separator: " ").first ?? "") else { return true }
        return n < version
    }
    static func record(defaults: UserDefaults = .standard) {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        defaults.set("\(version) \(f.string(from: Date()))", forKey: key)
        fputs("launcher: acknowledged (first start)\n", stderr)
    }

    // The panel over parent; after the press it goes and then() runs (the Gate shows, or the game starts)
    @MainActor static func present(on parent: UIViewController, artwork: LauncherArtwork, then: @escaping @MainActor () -> Void) {
        weak var host: UIViewController?
        let view = NX18AcknowledgeView(artwork: artwork) {
            record()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            guard let h = host else { return }
            host = nil
            // the next start presents from the same parent: one main-queue turn after the dismissal ends, or UIKit is still in its full-screen transition and drops it
            h.dismiss(animated: false) { DispatchQueue.main.async { then() } }
        }
        let h = DmHostingController(rootView: view)
        h.followAppearance()
        h.modalPresentationStyle = .fullScreen
        host = h
        fputs("launcher: the first-start acknowledgement shows\n", stderr)
        parent.present(h, animated: false)
    }
}

struct NX18AcknowledgeView: View {
    let artwork: LauncherArtwork
    let understood: () -> Void
    @StateObject private var pad = LauncherGamepad()
    @State private var done = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { g in
            let portrait = g.size.width < g.size.height || typeSize.isAccessibilitySize
            ZStack {
                artBehind.environment(\.colorScheme, .dark)   // the art behind the panel stays dark in every look (§11a.2)
                panel(portrait: portrait)
                    .frame(maxWidth: Swift.min(g.size.width - 32, 640))
                    .padding(16)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .ignoresSafeArea(.keyboard)
        .nxTextRoot()
        .task { await pad.run { e in if e == .a { press() } } }
    }

    private func panel(portrait: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            NX18Mark(height: 26, light: scheme == .light)
            let layout = portrait ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14)) : AnyLayout(HStackLayout(alignment: .center, spacing: 18))
            layout {
                Text(NX18Acknowledge.line).nxFont(.body).foregroundStyle(GateColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                button
            }
            if pad.connected {
                HStack(spacing: 5) {
                    NXPadGlyphView(pad.glyphs.glyph(.a), size: 15, relativeTo: .caption2).foregroundStyle(GateColor.line)
                    Text("I understand").nxFont(.caption).foregroundStyle(GateColor.muted)
                }
                .accessibilityHidden(true)
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(GateColor.slab))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(GateColor.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var button: some View {
        Button(action: press) {
            Text("I understand").nxFont(.headline, weight: .semibold).foregroundStyle(GateColor.ink)
                .padding(.horizontal, 22).frame(minWidth: 140, minHeight: 44)
                .background(Capsule().fill(GateColor.chosen))
                .overlay { if scheme == .light { Capsule().strokeBorder(GateColor.ring, lineWidth: 1.5) } }   // light: the blush alone is 1.30:1 off the panel (§21.2a)
                .overlay { if pad.connected { Capsule().strokeBorder(GateColor.ring, lineWidth: 2).padding(-4) } }   // the pad's focus starts here and stays
                .contentShape(Capsule())
        }
        .buttonStyle(NX18PressStyle())
        .keyboardShortcut(.defaultAction)   // Return; Space presses the focused button
        .accessibilityLabel("I understand")
    }

    var artOnly: some View { artBehind }   // the welcome's backdrop: the same art and scrim
    private var artBehind: some View {
        ZStack {
            NX18Palette.background(tint: artwork.tint)
            Color.clear.overlay {
                if let art = artwork.art { Image(uiImage: art).resizable().scaledToFill() }
                else if let icon = artwork.icon { Image(uiImage: icon).resizable().scaledToFill().blur(radius: 60, opaque: true).opacity(0.55).scaleEffect(1.15) }
            }
            .clipped()
            Color.black.opacity(0.55)   // the hero's scrim: the panel reads the same over any art
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func press() {
        guard !done else { return }
        done = true
        understood()
    }
}

// ---- The welcome (gate-ui §21.1-§21.3, G14): on the first Gate of each game app, before the Gate is built ----
// Three choices: Connect to my NX 18 folder, Create a profile, Not now. Any of them sets nx18.welcome; quitting without a choice shows it again next time. Not shown when the
// Gate is skipped (it waits for the next Gate) or with DM_WELCOME=0; DM_WELCOME=1 forces it. The acknowledgement keeps its own rule (it shows on its own, before, when due)
enum NX18WelcomeGate {
    static let key = "nx18.welcome"
    static func due(environment: [String: String] = ProcessInfo.processInfo.environment, defaults: UserDefaults = .standard) -> Bool {
        if environment["DM_WELCOME"] == "0" { return false }
        if environment["DM_WELCOME"] == "1" { return true }
        return !defaults.bool(forKey: key)
    }
    static func record(_ choice: String, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
        fputs("launcher: welcome: \(choice)\n", stderr)
    }

    @MainActor static func present(on parent: UIViewController, artwork: LauncherArtwork, then: @escaping @MainActor () -> Void) {
        weak var host: UIViewController?
        let view = NX18WelcomeView(artwork: artwork) {
            guard let h = host else { return }
            host = nil
            h.dismiss(animated: false) { DispatchQueue.main.async { then() } }
        }
        let h = DmHostingController(rootView: view)
        h.followAppearance()
        h.modalPresentationStyle = .fullScreen
        host = h
        fputs("launcher: the welcome shows\n", stderr)
        parent.present(h, animated: false)
    }
}

struct NX18WelcomeView: View {
    let artwork: LauncherArtwork
    let finished: () -> Void
    @StateObject private var pad = LauncherGamepad()
    @StateObject private var flow = NX18ProfileFlow()
    @ObservedObject private var profile = NX18Profile.shared
    @State private var step = Step.choose
    @State private var focus = 1          // choose: 0 Connect, 1 Create, 2 Not now; create steps: 0 Skip, 1 Next / Choose folder
    @State private var padLine: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    enum Step { case choose, createName, createFolder }

    var body: some View {
        GeometryReader { g in
            let portrait = g.size.width < g.size.height || typeSize.isAccessibilitySize
            ZStack {
                NX18AcknowledgeView(artwork: artwork, understood: {}).artOnly.environment(\.colorScheme, .dark)
                panel(portrait: portrait).frame(maxWidth: Swift.min(g.size.width - 32, 720)).padding(16)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .nxTextRoot()
        .nx18ProfileFlow(flow)
        .task { await pad.run { handle($0) } }
    }

    @ViewBuilder private func panel(portrait: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) { NX18Mark(height: 24, light: scheme == .light); Text("NX 18").nxFont(.title3, weight: .bold).foregroundStyle(GateColor.text) }
            switch step {
            case .choose: chooseStep(portrait: portrait)
            case .createName: nameStep
            case .createFolder: folderStep
            }
            if let b = flow.busy { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(b).nxFont(.caption).foregroundStyle(GateColor.muted) } }
            if pad.connected, let l = padLine ?? flow.strip { Text(l).nxFont(.caption).foregroundStyle(GateColor.text).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(GateColor.slab))
        .padding(6)
        .nx18Surface(RoundedRectangle(cornerRadius: 22, style: .continuous), fill: GateColor.slab, hairline: GateColor.hairline, tint: Color.black.opacity(0.25), art: artwork.art != nil)
        .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder private func chooseStep(portrait: Bool) -> some View {
        Text("Keep one profile and your cloud saves in one NX 18 folder, for all your games.").nxFont(.body).foregroundStyle(GateColor.text).fixedSize(horizontal: false, vertical: true)
        Text("Each game app asks for the folder once, and again if the app is re-signed.").nxFont(.caption).foregroundStyle(GateColor.muted).fixedSize(horizontal: false, vertical: true)
        let layout = portrait ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            tile(0, "Connect to my NX 18 folder", "Find your profile and cloud saves") { connect() }
            tile(1, "Create a profile", "A name and a picture for your games") { NX18WelcomeGate.record("create"); focus = 1; step = .createName }
            tile(2, "Not now", "Go to the Gate. You can do this later from the NX 18 mark.") { NX18WelcomeGate.record("not now"); finished() }
        }
    }
    @ViewBuilder private var nameStep: some View {
        Text("Create a profile").nxFont(.headline, weight: .semibold).foregroundStyle(GateColor.text)
        HStack(spacing: 16) {
            Button { flow.choosePicture(pad: false) } label: {
                VStack(spacing: 4) {
                    NX18ProfilePictureView(version: profile.pictureVersion, has: profile.hasPicture, url: profile.pictureURL).frame(width: 72, height: 72)
                    Text("Choose a picture").nxFont(.caption2).foregroundStyle(GateColor.line)
                }
            }
            .buttonStyle(NX18PressStyle())
            Button { flow.editName(pad: false) } label: {
                Text(verbatim: profile.name).nxFont(.title3, weight: .semibold).foregroundStyle(GateColor.text)
                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading).padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(GateColor.tile))
            }
            .buttonStyle(NX18PressStyle()).accessibilityLabel("Name").accessibilityValue(profile.name)
        }
        twoButtons(skip: "Skip", next: "Next", skipAction: { step = .createFolder }, nextAction: { step = .createFolder })
    }
    @ViewBuilder private var folderStep: some View {
        Text("Choose or create a folder named NX 18 in iCloud Drive.").nxFont(.body).foregroundStyle(GateColor.text).fixedSize(horizontal: false, vertical: true)
        if pad.connected { Text("The folder picker needs touch, a keyboard or a mouse. B closes it.").nxFont(.caption).foregroundStyle(GateColor.muted) }
        twoButtons(skip: "Skip", next: "Choose folder", skipAction: { finished() }, nextAction: { pickFolder() })
    }

    private func tile(_ i: Int, _ title: String, _ brief: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).nxFont(.subheadline, weight: .semibold).foregroundStyle(GateColor.text)
                Text(brief).nxFont(.caption).foregroundStyle(GateColor.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(pad.connected && focus == i ? GateColor.lit : GateColor.tile))
            .overlay { if pad.connected && focus == i { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(GateColor.ring, lineWidth: 2).padding(-3) } }
        }
        .buttonStyle(NX18PressStyle())
        .accessibilityLabel(title).accessibilityHint(brief)
    }
    private func twoButtons(skip: String, next: String, skipAction: @escaping () -> Void, nextAction: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Spacer()
            pill(skip, chosen: false, focusedHere: focus == 0, action: skipAction)
            pill(next, chosen: true, focusedHere: focus == 1, action: nextAction)
        }
    }
    private func pill(_ t: String, chosen: Bool, focusedHere: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).nxFont(.body, weight: .semibold).foregroundStyle(chosen ? GateColor.ink : GateColor.text)
                .padding(.horizontal, 20).frame(minWidth: 110, minHeight: 44)
                .background(Capsule().fill(chosen ? GateColor.chosen : GateColor.tile))
                .overlay { if pad.connected && focusedHere { Capsule().strokeBorder(GateColor.ring, lineWidth: 2).padding(-4) } }
        }
        .buttonStyle(NX18PressStyle())
    }

    private func connect() {
        NX18WelcomeGate.record("connect")
        flow.connecting = true
        flow.folderPicked = { ok in if ok { finished() } }
        flow.folderPicking = true
    }
    private func pickFolder() {
        flow.connecting = false
        flow.folderPicked = { _ in finished() }   // a cancelled pick keeps the Profile on this device ("NX 18 folder: not chosen" on the card)
        flow.folderPicking = true
    }

    private func handle(_ e: LauncherPadEvent) {
        padLine = nil
        switch step {
        case .choose:
            switch e {
            case .left, .up: focus = max(0, focus - 1)
            case .right, .down: focus = min(2, focus + 1)
            case .a: [connect, { NX18WelcomeGate.record("create"); focus = 1; step = .createName }, { NX18WelcomeGate.record("not now"); finished() }][focus]()
            default: break
            }
        case .createName, .createFolder:
            switch e {
            case .left: focus = 0
            case .right: focus = 1
            case .a:
                if step == .createName { padLine = "Typing a name and choosing a picture need touch or a keyboard."; step = .createFolder; focus = 1 }
                else if focus == 0 { finished() } else { pickFolder() }
            case .b: if step == .createFolder { step = .createName } else { step = .choose; focus = 1 }
            default: break
            }
        }
    }
}
