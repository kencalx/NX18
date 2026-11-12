// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json (an app of several programs: dm/p<N>/launcher.json), which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. All settings share one screen, grouped by section (rows: LauncherRow.swift). Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults shows the defaults, and Play then forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once with the saved choices; DM_SAVED_CHOICES=0 ignores them (and keeps them)
// The look (the NX 18 palette, LauncherRow.swift): the game's key art on the left (dm/art.jpg; without it the app icon, blurred behind and sharp on top), its logo (dm/logo.png) or else its name, the status line, the coral Play pill and,
// when the app has them, Game guide and About this game (GuideViewer.swift); the rails line; the settings on the right: the preset chips, the basic rows, Advanced (the other rows, collapsed,
// remembered as launcher.advanced), Reset, Cloud saves and Skip this screen next time (launcher.skip: the game starts at once, as with DM_LAUNCHER=0; the in-game menu's Settings screen
// at start turns it off, and a controller button held while the app opens shows the screen anyway, best effort; with cloud saves on, the screen shows for the cloud-save check that Play
// runs, and the game starts by itself when the check has nothing to ask, as it does for the Game shortcut, only with the app in front: LauncherShortcuts.swift). A narrow or portrait window puts the art on top. The background takes at most 12 % of the art's average colour; the accents,
// the rails and the mark keep the logo's colours. A game controller drives a focus ring over all of it (LauncherController.swift)
import CoreHaptics
import GameController
import Metal
#if canImport(MetalFX)
import MetalFX   // not in the Simulator's SDK: the Duo harness runs this screen there (dm/ios/tests/duo)
#endif
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }

// Whether front_ios.m startGame has made the process's first Metal device. Until it has, the facts leave MetalFX unknown (no greying): a device made here would come before
// front_hud_env, and the Metal device reads MTL_HUD_ENABLED, the launcher's Performance HUD switch, only when the process makes its first (GitHub issue #840)
@MainActor private var metalDeviceMade = false

// The device facts the rules are decided on (LauncherSettings.swift DeviceFacts), as front_ios.m tests the same things when the game starts: the app scene's screen and window
// (the TV's scene is not the app's), the haptic engine, the controllers, and a TV scene connected
@MainActor private func iosDeviceFacts() -> DeviceFacts {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let app = scenes.first { $0.session.role == .windowApplication }
    func ratio(_ s: CGSize?) -> Double? {
        guard let s, min(s.width, s.height) > 0 else { return nil }
        return Double(max(s.width, s.height) / min(s.width, s.height))
    }
    var f = DeviceFacts()
    f.kind = UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone
    f.screen = ratio(app?.screen.bounds.size)
    f.window = ratio(app?.effectiveGeometry.coordinateSpace.bounds.size)
    f.hz = app.map { $0.screen.maximumFramesPerSecond }
    f.haptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    f.controller = !GCController.controllers().isEmpty
    f.tv = scenes.contains { $0.session.role == .windowExternalDisplayNonInteractive }
#if canImport(MetalFX)
    if metalDeviceMade, let dev = MTLCreateSystemDefaultDevice() { f.metalFX = MTLFXSpatialScalerDescriptor.supportsMetal4FX(dev) }   // Metal 4 itself: the device check (main.m) refused a GPU without it
#else
    if metalDeviceMade { f.metalFX = false }   // no MetalFX in this build (the Simulator)
#endif
    // nvn_mtl.m's capture profile (pso4_capture): an app built with DM_METAL_CAPTURE=1 (MetalCaptureEnabled), which loads the capture layer; the layer is asked only once a device is made
    f.gpuCapture = (Bundle.main.object(forInfoDictionaryKey: "MetalCaptureEnabled") as? Bool) == true
        || (metalDeviceMade && MTLCaptureManager.shared().supportsDestination(.gpuTraceDocument))
    return f
}

// A settings row's card: the row colour, with the controller's focus as a cyan outline inside it (a List clips what is drawn outside a row)
private func rowBackground(_ focused: Bool, fill: Color = NX18Palette.row) -> some View {
    ZStack {
        fill
        if focused { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(NX18Palette.cyan, lineWidth: 2).padding(2) }
    }
}

/// Cloud saves: an iCloud Drive folder shared with the Mac app (chosen in its settings window's
/// Cloud saves too). The host brings the save in from there when the game starts and
/// sends it there after each save (dm/host/save_sync.h); the folder is a bookmark (CloudSaves.m).
private struct CloudSavesSection: View {
    @Binding var picking: Bool   // the folder picker is up (the settings screen's controller waits meanwhile; its A on this section opens it)
    var focused = false
    var closed: () -> Void = {}   // the picker has finished closing (a Guide shortcut waits for it)
    var changed: () -> Void = {}
    @State private var folder: String = ""
    @State private var note: String = ""

    var body: some View {
        Section {
            HStack {
                Text("Cloud saves")
                Spacer()
                Text(folder.isEmpty ? "Off" : (folder as NSString).lastPathComponent)
                    .foregroundStyle(NX18Palette.muted).lineLimit(1).truncationMode(.middle)
            }
            .listRowBackground(NX18Palette.row)
            Button(folder.isEmpty ? "Choose a folder in iCloud Drive…" : "Choose a different folder…") { picking = true }
                .foregroundStyle(NX18Palette.cyan)
                .listRowBackground(rowBackground(focused))
                .id(LauncherFocus.cloud)
                // The sheet sits on the button, not on the Section: SwiftUI hands a Section's modifiers to every row, so one tap presented a picker per row and they invalidated each other (LNPANDY/NX2Apple#315).
                .sheet(isPresented: $picking, onDismiss: closed) {
                    DocumentPicker(types: [.folder]) { url in
                        picking = false
                        if dm_store_cloud_saves(url) {
                            note = "Saved. The game uses this folder when you press Play."
                            refresh()
                        } else {
                            note = "That folder could not be remembered — try a different one."
                        }
                    } onCancel: { picking = false }
                }
            if !folder.isEmpty {
                Button("Turn off cloud saves") {
                    dm_clear_cloud_saves(); refresh(); note = ""
                }
                .foregroundStyle(NX18Palette.coral)
                .listRowBackground(NX18Palette.row)
            }
        } header: {
            NX18SectionHeader("Saves")
        } footer: {
            Text(note.isEmpty
                 ? "Choose a folder in iCloud Drive, and the same one in the Mac app's Cloud saves. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in save-backups."
                 : note)
            .nxFontIfCustom(.footnote)
            .foregroundStyle(NX18Palette.muted)
        }
        .listRowSeparatorTint(NX18Palette.separator)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        var stale: ObjCBool = false
        folder = dm_cloud_saves_path(&stale) ?? ""
        if stale.boolValue && folder.isEmpty {
            note = "The folder you chose before is no longer readable (the app was signed differently). Please choose it again."
        }
        changed()
    }
}

/// UIDocumentPickerViewController for a folder, in the two callbacks a SwiftUI sheet wants.
private struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.folder]
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .open (not .import): the folder stays where it is and the bookmark keeps pointing at it.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

// The coral Play pill's and the small buttons' press: a little dimmer and smaller while held
private struct NX18PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.82 : 1).scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

// The screen's switches as in the mockup: the track cyan when on and #4A4A50 when off (the system's off track all but disappears on the #333337 rows), a white knob. Set on
// the whole screen, so the setting rows' toggles (LauncherRow.swift, shared with the Mac, which keeps its own) take it; a tap anywhere on the row flips it, as VoiceOver's activate does
private struct NX18SwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { NX18Switch(configuration: configuration) }
}
private struct NX18Switch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled   // a fixed or greyed row (SettingRow's .disabled): shown, not flipped
    var body: some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 0)
            NX18SwitchTrack(on: configuration.isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { if enabled { configuration.isOn.toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction { if enabled { configuration.isOn.toggle() } }
    }
}
private struct NX18SwitchTrack: View {
    let on: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Capsule().fill(on ? NX18Palette.cyan : Color(nx18: 0x4A4A50))
            .frame(width: 51, height: 31)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).padding(2.5).shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            }
            .opacity(enabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: on)
    }
}

private enum LauncherSheet: Identifiable { case guide, about; var id: Self { self } }

// The stacked layout's art side: as tall as its content needs at the width it gets (its ideal height), but at least least and at most most, its content then laid out at that
// height (the Spacer above the name takes what is left). A fixed frame let a large text size or a short window push Play under the settings
private struct HeroHeight: Layout {
    let least: CGFloat
    let most: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let v = subviews.first else { return .zero }
        let w = proposal.width ?? v.sizeThatFits(.unspecified).width
        let need = v.sizeThatFits(ProposedViewSize(width: w, height: nil)).height
        return CGSize(width: w, height: Swift.min(Swift.max(need, least), Swift.max(most, least)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

// The settings screen. Internal (not private) so a harness or a preview can show it with its own model and content
struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let dir: URL?                  // the folder launcher.json came from (DM_APP_DM or <App>/dm)
    let artwork: LauncherArtwork
    let play: () -> Void
    let startWith: LauncherShortcut?   // a home screen shortcut the screen opened for (Guide: the guide open); LauncherShortcuts.swift
    let checkAtStart: Bool             // shown for the cloud-save check of a start that skips the screen (Skip this screen next time, the Game shortcut): Play's check runs as it appears
    @State private var content: LauncherContent
    @State private var startTaken = false
    @StateObject private var pad = LauncherGamepad()
    @State private var focus: LauncherFocus? = .play
    @State private var sheet: LauncherSheet?
    @State private var cloudPicking = false
    @State private var guideAfter = false   // a Guide shortcut waiting for About or the folder picker to finish closing: UIKit presents nothing from a view controller that is still presenting, so the guide opens after
    @State private var status = LauncherStatus()
    @State private var scroller = LauncherScroller()
    @State private var textHeight: CGFloat = 140   // the name, status line and buttons over the art: the height the scrim under them covers
    @State private var checking = false            // Play is comparing this iPhone's save with the cloud's (start)
    @State private var check = 0                   // which Play the running check is for: one the player went on from without it is dropped
    @State private var autoCheck = 0               // the check that runs by itself for a skipped start (checkAtStart), 0 when none: the player asking for the screen stops it (stopAutoStart)
    @State private var held: HeldStart?            // a check's answer that came while the app was not active: the game starts when it is next in front (startHeld)
    @State private var report: SaveSyncReport?
    @State private var asking: SaveSyncReport.Step?
    @AppStorage("launcher.advanced") private var advancedOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(m: LauncherModel, dir: URL?, content: LauncherContent, artwork: LauncherArtwork, startWith: LauncherShortcut? = nil, checkAtStart: Bool = false, play: @escaping () -> Void) {
        self.m = m; self.dir = dir; self.artwork = artwork; self.startWith = startWith; self.checkAtStart = checkAtStart; self.play = play
        _content = State(initialValue: content)
    }

    private var name: String { (info("CFBundleDisplayName") as? String) ?? (info("CFBundleName") as? String) ?? "Game" }
    private var version: String? { (info("CFBundleShortVersionString") as? String).flatMap { $0.isEmpty ? nil : $0 } }
    private var background: Color { NX18Palette.background(tint: artwork.tint) }
    private var basicGroups: [LauncherRowGroup] { m.groups(basic: true) }
    private var advancedGroups: [LauncherRowGroup] { m.groups(basic: false) }
    private var launcherFromEnv: Bool { LauncherModel.launcherSetByEnv() }   // an env file's or the launch's DM_LAUNCHER, not main.m's for a program record
    private func ring(_ f: LauncherFocus) -> Bool { pad.connected && focus == f && sheet == nil }

    var body: some View {
        GeometryReader { g in
            let wide = g.size.width > g.size.height * 1.15 && g.size.width >= 640
            let tall = Swift.min(Swift.max(g.size.height * 0.4, 250), 400)
            Group {
                if wide {
                    HStack(spacing: 0) {
                        hero(wide: true, width: (g.size.width * 0.55).rounded(), height: g.size.height).frame(width: (g.size.width * 0.55).rounded())
                        NX18Rails(flowing: true).ignoresSafeArea(edges: .vertical)
                        settings
                    }
                } else {
                    VStack(spacing: 0) {
                        // at least tall, and as tall as its text and buttons need (a large text size, a short window) up to 70 % of the window: they never slide under the settings
                        HeroHeight(least: tall, most: Swift.max(tall, g.size.height * 0.7)) { hero(wide: false, width: g.size.width, height: tall) }
                            .clipped()
                        NX18Rails(axis: .horizontal, flowing: true).ignoresSafeArea(edges: .horizontal)
                        settings
                    }
                }
            }
            .onChange(of: g.size) { m.refreshFacts() }   // the window's shape: rotated, or resized under Stage Manager or Split View
        }
        .background(background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)   // a fullScreenCover from a light-mode app keeps its light traits otherwise, which drew the settings' names black
        .nxTextRoot()   // NX 18's UI font for every text below that names no style (NXFont.swift); the guide and About set it again on their own roots
        .tint(NX18Palette.cyan)
        .toggleStyle(NX18SwitchStyle())
        .fullScreenCover(isPresented: shown(.guide)) {
            LauncherGuideSheet(content: content, scroller: scroller, closeGlyph: pad.connected ? pad.glyphs.glyph(.b) : nil) { sheet = nil }
        }
        .sheet(isPresented: shown(.about), onDismiss: guideAfterClosing) {
            LauncherAboutSheet(about: content.about ?? LauncherAbout(), artwork: artwork, name: name, version: version, scroller: scroller,
                               closeGlyph: pad.connected ? pad.glyphs.glyph(.b) : nil) { sheet = nil }
                .presentationBackground(background)
        }
        // The controller sentences name the buttons as the pad labels them (pad.glyphs): handle gets Switch buttons by position, so on an Xbox pad Switch B is its A. L and R are the same on every pad
        .confirmationDialog(SaveSyncReport.chooseTitle, isPresented: isAsking(.choose), titleVisibility: .visible, presenting: report) { r in
            Button(r.localLabel(here: "iPhone")) { go(r.localChoice) }
            Button(r.cloudLabel) { go(r.cloudChoice) }
            Button("Cancel", role: .cancel) {}
        } message: { r in Text(r.chooseMessage(here: "iPhone") + (pad.connected ? " With a controller: L plays this iPhone's, R the cloud's, \(pad.glyphs.name(.b)) cancels." : "")) }
        .confirmationDialog(SaveSyncReport.unreadableTitle, isPresented: isAsking(.unreadable), titleVisibility: .visible, presenting: report) { r in
            Button("Play This iPhone's Save") { go("offline") }   // the mount does not wait for the cloud again
            Button("Try Again") { DispatchQueue.main.async { start() } }
            Button("Cancel", role: .cancel) {}
        } message: { r in Text(r.unreadableMessage(here: "iPhone") + (pad.connected ? " With a controller: \(pad.glyphs.name(.a)) plays this iPhone's save, \(pad.glyphs.name(.y)) tries again, \(pad.glyphs.name(.b)) cancels." : "")) }
        .task { await pad.run { handle($0) } }
        .task { await followStatus() }
        .onChange(of: sheet) {          // a button held as a sheet opens or closes (A held while B closes the guide) is no press on what is under it
            pad.holdUntilReleased()
            if sheet != nil { stopAutoStart("the guide or About this game opened") }
        }
        .onChange(of: cloudPicking) { pad.holdUntilReleased(); if cloudPicking { stopAutoStart("the cloud-save folder picker opened") } }
        .onChange(of: asking) { pad.holdUntilReleased() }        // the press that answered a save question is no press on the settings
        .onReceive(LauncherShortcuts.requests) { shortcut($0) }   // a home screen shortcut chosen while the screen is up
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in startHeld() }   // back in front: a held start goes
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in startHeld() }   // came first in the iOS 27.3 Simulator, the application still inactive, and the application's then started it: this one is for an application that stays active (a TV's scene, not tried)
        .onAppear {
            guard !startTaken else { return }
            if let s = startWith { startTaken = true; shortcut(s) }   // the one the app was opened with
            else if checkAtStart { startTaken = true; start(); autoCheck = check }   // a skipped start's cloud-save check: as if Play had been pressed, the game starting by itself when nothing is asked
        }
    }

    // A home screen shortcut on this screen (LauncherShortcuts.swift): Game plays, Launcher closes what is over the screen (the guide, About, the folder picker) and stays, Guide
    // opens the guide, else the manual, else About this game
    private func shortcut(_ s: LauncherShortcut) {
        switch s {
        case .game: fputs("launcher: shortcut Game: Play\n", stderr); start()
        case .launcher:
            stopAutoStart("shortcut Launcher")
            if sheet != nil || cloudPicking { fputs("launcher: shortcut Launcher: back to the settings\n", stderr) }
            sheet = nil; cloudPicking = false; guideAfter = false
        case .guide:
            stopAutoStart("shortcut Guide")
            // What the guide replaces (About, the folder picker) closes first, and the guide opens once it has gone (guideAfterClosing): changing one presentation for another in a
            // single update asked UIKit to present from a view controller that was still presenting
            let wanted: LauncherSheet? = content.hasGuide ? .guide : content.hasAbout ? .about : nil
            if wanted != nil && (cloudPicking || (sheet != nil && sheet != wanted)) {
                fputs("launcher: shortcut Guide: closing what is over the settings first\n", stderr)
                guideAfter = true; sheet = nil; cloudPicking = false
                Task { try? await Task.sleep(for: .seconds(1.5)); guideAfterClosing() }   // in case no dismissal is reported (the sheet had not appeared yet)
            } else { cloudPicking = false; guideNow() }
        }
    }

    // The Guide shortcut's sheet: the guide, else the manual (both in LauncherGuideSheet), else About this game
    private func guideNow() {
        if content.hasGuide { openGuide() }
        else if content.hasAbout { sheet = .about }
        else { fputs("launcher: shortcut Guide: this app has no guide, manual or About this game; the settings screen stays\n", stderr) }
    }
    // About or the folder picker has finished closing: the guide a Guide shortcut waits for opens now
    private func guideAfterClosing() {
        guard guideAfter else { return }
        guideAfter = false
        guideNow()
    }

    private func shown(_ s: LauncherSheet) -> Binding<Bool> {
        Binding(get: { sheet == s }, set: { if !$0, sheet == s { sheet = nil } })
    }

    // MARK: The art side

    private func hero(wide: Bool, width: CGFloat, height: CGFloat) -> some View {
        let iconSide = Swift.min(Swift.max(height * 0.3, wide ? 96 : 72), 150)
        return VStack(alignment: .leading, spacing: 0) {
            NX18Mark(height: 20)
                .background { if artwork.art != nil { NX18MarkShade(strong: reduceTransparency) } }   // over art only: the plain backdrop is dark already
            if artwork.art == nil, height >= 300, let icon = artwork.icon {   // the sharp icon only where it leaves the name and buttons room (the blurred one stays behind)
                Image(uiImage: icon).resizable().aspectRatio(1, contentMode: .fit)
                    .frame(width: iconSide, height: iconSide)
                    .clipShape(RoundedRectangle(cornerRadius: iconSide * 0.2237, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
                    .padding(.top, 18)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 10)
            VStack(alignment: .leading, spacing: 0) {
                // the game's logo in place of its name when the app has one: about 96 pt tall on an iPhone's landscape hero, at most 22 % of a shorter (stacked) hero's height
                // and 70 % of its width; VoiceOver still reads the name
                if let logo = artwork.logo {
                    NX18GameLogo(image: Image(uiImage: logo), natural: logo.size, name: name, dark: artwork.logoDark, maxWidth: width * 0.7, maxHeight: Swift.min(96, height * 0.22))
                } else {
                    Text(name)
                        .nxFont(.title, weight: .bold).foregroundStyle(.white)
                        .lineLimit(2).minimumScaleFactor(0.7)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
                        .accessibilityAddTraits(.isHeader)
                }
                LauncherStatusLine(status: status, color: NX18Palette.onArt).padding(.top, 5)
                actions.padding(.top, 16)
                if checking { checkingLine.padding(.top, 10) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }   // the art layer's scrim covers this much
        }
        .padding(.leading, 24).padding(.trailing, 20).padding(.top, 18).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .background { artLayer(wide: wide).ignoresSafeArea() }
    }

    // The art aspect-filled and clipped (else the icon enlarged and blurred), fading into the background to the right (beside the settings) and to the bottom
    private func artLayer(wide: Bool) -> some View {
        ZStack {
            background
            Color.clear.overlay {
                if let art = artwork.art { Image(uiImage: art).resizable().scaledToFill() }
                else if let icon = artwork.icon { Image(uiImage: icon).resizable().scaledToFill().blur(radius: 60, opaque: true).opacity(0.55).scaleEffect(1.15) }
            }
            .clipped()
            if wide {
                LinearGradient(stops: [.init(color: background.opacity(0), location: 0.55), .init(color: background, location: 1)], startPoint: .leading, endPoint: .trailing)
            }
            topShade
            LinearGradient(stops: [.init(color: background.opacity(0), location: wide ? 0.45 : 0.35), .init(color: background.opacity(wide ? 0.92 : 1), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            // a scrim under the name, status line and buttons, whatever the art (a bright sky or a white logo field): from clear 48 pt above the name to most of the background
            // under the text, across the whole art side and into the safe areas, so the muted text keeps its contrast
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(stops: [.init(color: background.opacity(0), location: 0), .init(color: background.opacity(reduceTransparency ? 0.9 : 0.72), location: 0.35),
                                       .init(color: background.opacity(reduceTransparency ? 0.95 : 0.86), location: 1)], startPoint: .top, endPoint: .bottom)
                    .frame(height: textHeight + 48 + 20 + 24)   // above the name, the hero's bottom padding, and the bottom safe area it runs into
            }
        }
        .accessibilityHidden(true)   // decorative
    }

    // A soft shade down from the top edge, behind the small NX 18 mark, so it reads over bright art (a sky, a white field): black at a third at the very top (a little more
    // under Reduce Transparency), fading out over about 120 pt on an eased curve, so it shows no edge or band. Across the whole art side, from the top of the screen (it runs
    // into the safe area with the art)
    private var topShade: some View {
        let top = reduceTransparency ? 0.45 : 0.34
        return VStack(spacing: 0) {
            LinearGradient(stops: [.init(color: .black.opacity(top), location: 0), .init(color: .black.opacity(top * 0.72), location: 0.25),
                                   .init(color: .black.opacity(top * 0.38), location: 0.5), .init(color: .black.opacity(top * 0.12), location: 0.75),
                                   .init(color: .black.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
            Spacer(minLength: 0)
        }
    }

    // Play, then the guide and About when the app has them, and "Press A to play" (+ while the outline is elsewhere) while a controller is connected: in one line, with the buttons' full names when they fit, else
    // without the hint, else short names, else icons only; else Play above the rest
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { playButton; guideButton(.full); aboutButton(.full); padHint }
            HStack(spacing: 12) { playButton; guideButton(.full); aboutButton(.full) }
            HStack(spacing: 10) { playButton; guideButton(.short); aboutButton(.short); padHint }
            HStack(spacing: 10) { playButton; guideButton(.short); aboutButton(.short) }
            HStack(spacing: 10) { playButton; guideButton(.icon); aboutButton(.icon) }
            VStack(alignment: .leading, spacing: 10) {
                playButton
                HStack(spacing: 10) { guideButton(.icon); aboutButton(.icon); padHint }
            }
        }
    }
    private enum ButtonLabel { case full, short, icon }

    private var playButton: some View {
        Button(action: start) {
            HStack(spacing: 10) {
                Image(systemName: "play.fill").font(.body.weight(.bold))   // system: symbol
                Text("Play").nxFont(.title3, weight: .bold)
            }
            .foregroundStyle(NX18Palette.charcoal)
            .padding(.horizontal, 34).frame(minHeight: 46)
            .background(Capsule().fill(NX18Palette.coral))
            .contentShape(Capsule())
        }
        .buttonStyle(NX18PressStyle())
        .nx18Focus(ring(.play), cornerRadius: 100)
        .accessibilityLabel("Play")
        .accessibilityHint("Starts the game with these settings")
        .keyboardShortcut(.defaultAction)
        .disabled(checking)
    }

    // While Play compares the saves (an iCloud download can take a while): say so, and let the player go on without the cloud's
    private var checkingLine: some View {
        HStack(spacing: 8) {
            ProgressView().tint(NX18Palette.onArt)
            Text("Checking the cloud save…").nxFont(.callout).foregroundStyle(NX18Palette.onArt)
            Button { playWithout() } label: {
                HStack(spacing: 5) {
                    Text("Play Without It")
                    if pad.connected { NXPadGlyphView(pad.glyphs.glyph(.b), size: 15, relativeTo: .callout) }   // the pad's own button for Switch B: the bottom one, labelled A, on an Xbox pad
                }
            }
            .nxFont(.callout, weight: .semibold).tint(NX18Palette.cyan)
            .accessibilityLabel("Play Without It")
            .accessibilityHint(pad.connected ? "Or press \(pad.glyphs.name(.b))" : "")
        }
    }

    // MARK: Cloud saves before Play (SaveSyncReport.swift, shared with the Mac's launcher)

    private func isAsking(_ step: SaveSyncReport.Step) -> Binding<Bool> {
        Binding(get: { asking == step }, set: { if !$0 && asking == step { asking = nil } })
    }

    /// Play, once the cloud's save is compared with this iPhone's (save_sync_report, SaveSyncReport): a save that changed on both sides is the player's pick, not the
    /// newer file's, and a cloud save that did not come is said so before the game starts without it. Every Play goes through here: the button, A on Play, +, the Game shortcut,
    /// and, with cloud saves on, a start that skips this screen (Skip this screen next time, the Game shortcut at a cold start: checkAtStart), which shows the screen only for this.
    /// An answer to play that comes while the app is not active waits for it to be back in front (startHeld)
    private func start() {
        if checking { return }
        check += 1; checking = true; asking = nil; held = nil   // a held answer is old: this Play checks again
        let mine = check
        dm_cloud_saves_env()   // DM_SAVE_SYNC from the picked folder, as the game's mount will read it (front_ios.m calls it again at the start)
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Self.compare()
            DispatchQueue.main.async {
                guard checking, check == mine else { return }   // the player played without it
                checking = false
                switch SaveSyncReport.step(r) {
                case .play(let choice) where !LauncherShortcuts.appActive():
                    // The check ended while the player was away (it can take a minute while iCloud downloads), or under a system alert (the notifications prompt a game of several
                    // programs asks at its first start): the game starts when the app is back in front (startHeld), not in the background, where its first Metal work would be refused.
                    // A check Play started is held the same way: Play was pressed in front, but the player may have left since
                    held = HeldStart(check: mine, choice: choice)
                    fputs("launcher: the cloud-save check ended with the app not active (in the background, or under a system alert): the game starts when the app is back in front\n", stderr)
                case .play(let choice): go(choice)
                case let step: report = r; asking = step   // a question waits on the screen by itself
                }
            }
        }
    }

    private func playWithout() { checking = false; go("offline") }

    /// A check's answer that came while the app was not active (start), for the start when it is back in front
    private struct HeldStart { let check: Int; let choice: String? }

    /// The app is in front again (UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification): the held start goes, once. A shortcut handed over as the app came back
    /// goes first (LauncherShortcuts.waiting, at most 5 s as perform waits): a Launcher or Guide one drops a skipped start's answer (stopAutoStart), Game checks again (start), and
    /// a notification for another scene, with the app's own still not in front, leaves it held
    private func startHeld(waited: Int = 0) {
        guard held != nil, LauncherShortcuts.appActive() else { return }
        if LauncherShortcuts.waiting > 0 && waited < 100 {
            Task { @MainActor in try? await Task.sleep(for: .milliseconds(50)); startHeld(waited: waited + 1) }
            return
        }
        guard let h = held else { return }   // taken meanwhile: a shortcut dropped it, or another notification started it
        held = nil
        fputs("launcher: the app is back in front: the held start goes\n", stderr)
        go(h.choice)
    }

    /// The check a skipped start runs by itself (checkAtStart) stops when the player asks for the screen while it runs (a Launcher or Guide shortcut, the guide, About this game
    /// or the folder picker opened): the game does not start under them when it ends, and Play checks again. Its answer held for the app's return (startHeld) is dropped the same
    /// way. A check Play started carries on, as it always did
    private func stopAutoStart(_ why: String) {
        guard autoCheck != 0 else { return }
        let running = checking && check == autoCheck
        if held?.check == autoCheck {   // it ended while the app was away, and the player came back asking for the screen
            held = nil
            fputs("launcher: the held start of the skipped start's cloud-save check dropped (\(why)): the settings screen stays, and Play checks again\n", stderr)
        }
        autoCheck = 0
        guard running else { return }
        checking = false   // its answer is dropped (start: guard checking)
        fputs("launcher: the cloud-save check of the skipped start stopped (\(why)): the settings screen stays, and Play checks again\n", stderr)
    }

    /// Blocks while the cloud's file downloads (SaveSyncReport.waitMs at most). nil: no report (the host then decides as it always did)
    nonisolated private static func compare() -> SaveSyncReport? {
        // getenv, not ProcessInfo.environment: main.m sets DM_SAVE and applies env.txt after that snapshot
        guard let save = getenv("DM_SAVE") else { fputs("launcher: save sync: no DM_SAVE\n", stderr); return nil }
        guard let line = SaveSyncReport.run({ save_sync_report(save, dm_save_title(), nil, SaveSyncReport.waitMs, $0, $1) }) else {
            fputs("launcher: save sync: no report on \(String(cString: save))\n", stderr)
            return nil
        }
        fputs("launcher: save sync: \(line)\n", stderr)
        let r = SaveSyncReport(line: line)
        if r?.pullPending == true { fputs("launcher: save sync: \(SaveSyncReport.pullPendingNote)\n", stderr) }
        return r
    }

    private func go(_ choice: String?) {
        asking = nil; held = nil
        if let choice { setenv("DM_SAVE_SYNC_CHOICE", choice, 1); fputs("launcher: DM_SAVE_SYNC_CHOICE=\(choice)\n", stderr) }
        play()
    }

    @ViewBuilder private func guideButton(_ l: ButtonLabel) -> some View {
        if content.hasGuide {
            let title = content.guide != nil ? "Game guide" : "Manual"
            smallButton(title, short: content.guide != nil ? "Guide" : "Manual", icon: "book.closed", label: l, focus: .guide, pad: .y) { openGuide() }
        }
    }
    @ViewBuilder private func aboutButton(_ l: ButtonLabel) -> some View {
        if content.hasAbout { smallButton("About this game", short: "About", icon: "info.circle", label: l, focus: .about) { sheet = .about } }
    }
    // pad: the controller button that presses it from anywhere on the screen (Y: the guide), its glyph at the end of a named button while a controller is connected
    private func smallButton(_ title: String, short: String, icon: String, label: ButtonLabel, focus f: LauncherFocus, pad button: NXButton? = nil,
                             action: @escaping () -> Void) -> some View {
        let fill = NX18Palette.row.opacity(reduceTransparency || artwork.art == nil ? 1 : 0.82)
        let glyph = pad.connected ? button.map { pad.glyphs.glyph($0) } : nil
        return Button(action: action) {
            Group {
                switch label {
                case .full, .short:
                    HStack(spacing: 7) {
                        Label(label == .full ? title : short, systemImage: icon).labelStyle(.titleAndIcon)
                        if let glyph { NXPadGlyphView(glyph, size: 17, relativeTo: .subheadline).foregroundStyle(NX18Palette.cyan) }
                    }
                    .padding(.leading, 14).padding(.trailing, glyph != nil ? 10 : 14)
                case .icon: Image(systemName: icon).frame(width: 40)
                }
            }
            .nxFont(.subheadline, weight: .semibold).foregroundStyle(.white).lineLimit(1).fixedSize()
            .frame(minHeight: 40)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(NX18Palette.separator, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(NX18PressStyle())
        .nx18Focus(ring(f), cornerRadius: 100)
        .accessibilityLabel(title)
        .accessibilityHint(glyph != nil && button != nil ? "Or press \(pad.glyphs.name(button ?? .y))" : "")
    }

    @ViewBuilder private var padHint: some View {
        if pad.connected {
            // A presses what the outline is on, so it plays only while the outline is on Play; + plays from anywhere
            let onPlay = focus == .play
            let button: NXButton = onPlay ? .a : .plus
            HStack(spacing: 4) {
                Text("Press")
                NXPadGlyphView(pad.glyphs.glyph(button), size: 17, relativeTo: .footnote).foregroundStyle(NX18Palette.coral)   // Play's coral
                Text("to play")
            }
            .nxFont(.footnote).foregroundStyle(NX18Palette.onArt).fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Press \(pad.glyphs.name(button)) to play")   // the button the glyph shows: the right one, B on an Xbox pad
        }
    }

    // MARK: The settings side

    private var focusedPreset: LauncherPreset? {
        guard pad.connected, sheet == nil, case .preset(let p)? = focus else { return nil }
        return p
    }

    private var settings: some View {
        ScrollViewReader { proxy in
            List {
                if m.hasPresets {
                    Section {
                        PresetChips(m: m, focused: focusedPreset)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 0, trailing: 4))
                            .id(LauncherFocus.preset(.balanced))
                    }
                }
                rows(basicGroups)
                if !advancedGroups.isEmpty {
                    Section {
                        Button { toggleAdvanced() } label: {
                            HStack {
                                Text("Advanced settings").foregroundStyle(.white)
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(NX18Palette.muted)   // system: symbol
                                    .rotationEffect(.degrees(advancedOpen ? 90 : 0))
                            }
                            .contentShape(Rectangle())
                        }
                        .listRowBackground(rowBackground(ring(.advanced)))
                        .accessibilityValue(advancedOpen ? "Shown" : "Hidden")
                        .accessibilityHint(advancedOpen ? "Hides the other settings" : "Shows the other settings")
                        .id(LauncherFocus.advanced)
                    }
                    if advancedOpen { rows(advancedGroups) }
                }
                Section {
                    Button("Reset to tested defaults") { m.reset() }
                        .foregroundStyle(NX18Palette.coral.opacity(m.changed ? 1 : 0.55))
                        .disabled(!m.changed)
                        .listRowBackground(rowBackground(ring(.reset), fill: .clear))
                        .id(LauncherFocus.reset)
                } footer: {
                    Text("Brings back all settings this game was tested with.").nxFontIfCustom(.footnote).foregroundStyle(NX18Palette.muted)
                }
                CloudSavesSection(picking: $cloudPicking, focused: ring(.cloud), closed: guideAfterClosing) { refreshCloud() }
                Section {
                    Toggle(isOn: $m.skipAtStart) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Skip this screen next time")
                            Text(launcherFromEnv
                                 ? "DM_LAUNCHER in an env file decides this"
                                 : "The game starts at once with these settings. To see this screen again, use Settings screen at start in the in-game menu (or hold a controller button while the app opens).")
                                .nxFont(.footnote).foregroundStyle(NX18Palette.muted)
                        }
                    }
                    .disabled(launcherFromEnv)
                    .listRowBackground(rowBackground(ring(.skip)))
                    .id(LauncherFocus.skip)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let v = version { Text("Version \(v)") }
                        Text(NX18Credits.buttonIcons)
                    }
                    .nxFontIfCustom(.footnote).foregroundStyle(NX18Palette.muted)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(background)
            .listSectionSpacing(14)
            .onChange(of: focus) { _, f in
                guard pad.connected, let f, f != .play, f != .guide, f != .about else { return }
                let id: LauncherFocus
                if case .preset = f { id = .preset(.balanced) } else { id = f }
                if reduceMotion { proxy.scrollTo(id) } else { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id) } }
            }
        }
    }

    private func rows(_ groups: [LauncherRowGroup]) -> some View {
        ForEach(groups) { g in
            Section {
                ForEach(g.rows) { s in
                    SettingRow(s: s, m: m)
                        .listRowBackground(rowBackground(ring(.row(s.env))))
                        .id(LauncherFocus.row(s.env))
                }
            } header: {
                NX18SectionHeader(g.section)
            }
            .listRowSeparatorTint(NX18Palette.separator)
        }
    }

    private func toggleAdvanced() {
        if reduceMotion { advancedOpen.toggle() } else { withAnimation(.easeInOut(duration: 0.2)) { advancedOpen.toggle() } }
    }

    private func openGuide() {
        guard content.hasGuide else { return }
        // the guide in the language picked now (Game language may have changed since the screen appeared)
        let lang = m.values["DM_LANG"] ?? ProcessInfo.processInfo.environment["DM_LANG"]
        content = LauncherContent.find(dir: dir, lang: lang)
        if content.hasGuide { sheet = .guide }
    }

    // MARK: The status line: the console and last played (once), cloud saves (as the section changes) and free memory (every 2 s)

    private func followStatus() async {
        let saves = ProcessInfo.processInfo.environment["DM_SAVE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("save")
        if let saves { status.lastPlayed = await Task.detached(priority: .utility) { LauncherStatus.lastModified(under: saves) }.value }
        status.console = m.console.flatMap(LauncherStatus.Console.init(rawValue:))
        refreshCloud()
        while !Task.isCancelled {
            let free = os_proc_available_memory()
            status.memoryFree = free > 0 ? UInt64(free) : nil
            try? await Task.sleep(for: .seconds(2))
        }
    }
    private func refreshCloud() { status.cloud = dm_cloud_saves_path(nil) != nil ? .on : .off }

    // MARK: The controller (LauncherController.swift)

    private var focusMap: LauncherFocusMap {
        var lines: [[LauncherFocus]] = []
        if m.hasPresets { lines.append(LauncherPreset.allCases.map { .preset($0) }) }
        var top: [LauncherFocus] = [.play]
        if content.hasGuide { top.append(.guide) }
        if content.hasAbout { top.append(.about) }
        lines.append(top)
        lines += basicGroups.flatMap { $0.rows.map { [LauncherFocus.row($0.env)] } }
        if !advancedGroups.isEmpty {
            lines.append([.advanced])
            if advancedOpen { lines += advancedGroups.flatMap { $0.rows.map { [LauncherFocus.row($0.env)] } } }
        }
        lines += [[.reset], [.cloud], [.skip]]
        return LauncherFocusMap(lines: lines)
    }

    private func handle(_ e: LauncherPadEvent) {
        if let open = sheet {   // a viewer is up: what it takes itself (the guide's page: every button but ZL / ZR, GuideViewer.swift), else B closes it, up / down scroll, L / R switch between the guide and the manual
            if scroller.pad?(e) == true { return }
            switch e {
            case .b: sheet = nil
            case .up: scroller.scroll?(-160)
            case .down: scroller.scroll?(160)
            case .l, .left: if open == .guide { scroller.page?(-1) }
            case .r, .right: if open == .guide { scroller.page?(1) }
            default: break
            }
            return
        }
        if cloudPicking { return }   // the system's folder picker: touch only
        if let step = asking, let r = report {   // which save to play, or what to do without the cloud's: the dialog's buttons by controller
            switch (step, e) {
            case (.choose, .l): go(r.localChoice)
            case (.choose, .r): go(r.cloudChoice)
            case (.unreadable, .a): go("offline")
            case (.unreadable, .y): asking = nil; DispatchQueue.main.async { start() }
            case (_, .b): asking = nil
            default: break
            }
            return
        }
        if checking { if e == .b { playWithout() }; return }   // B plays without the cloud's save; nothing else while it is compared
        let map = focusMap
        let cur = focus.flatMap { map.contains($0) ? $0 : nil } ?? .play
        if focus != cur { focus = cur }
        switch e {
        case .up, .down: focus = map.vertical(cur, e == .down ? 1 : -1)
        case .left, .right:
            let d = e == .right ? 1 : -1
            if let f = map.horizontal(cur, d) { focus = f }
            else if case .row(let env) = cur, let s = m.settings.first(where: { $0.env == env }) { m.advance(s, by: d) }
            else if cur == .advanced, advancedOpen != (d > 0) { toggleAdvanced() }
        case .a: activate(cur)
        case .plus: start()
        case .y: openGuide()
        case .b, .x, .minus, .l, .r, .zl, .zr: break
        }
    }

    private func activate(_ f: LauncherFocus) {
        switch f {
        case .preset(let p): m.applyPreset(p)
        case .play: start()
        case .guide: openGuide()
        case .about: if content.hasAbout { sheet = .about }
        case .row(let env):
            if let s = m.settings.first(where: { $0.env == env }), s.kind != "range" { m.advance(s, by: 1) }
        case .advanced: toggleAdvanced()
        case .reset: if m.changed { m.reset() }
        case .cloud: cloudPicking = true
        case .skip: if !launcherFromEnv { m.skipAtStart.toggle() }
        }
    }
}

// Shows the launcher over the root view controller and calls done once the settings are in the environment; false (done is not called) when there is no launcher, or when it is
// skipped. True also while the player's own skip waits a moment for a held controller button: done is then called (the game starts) without the screen, or the screen shows. With
// cloud saves on, a skip the player chose (Skip this screen next time, the Game shortcut) returns true and shows the screen running the cloud-save check, which calls done itself
// when there is nothing to ask
@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    nonisolated(unsafe) let viewController = viewController, done = done   // a raw pointer and a C callback: not Sendable, but front_ios.m hands them over on the main thread, where they stay
    return MainActor.assumeIsolated {   // front_ios.m calls it from its view controller on the main thread (UIKit); gameMenuModel is main-actor state (GameMenu.swift)
        // a game of several programs (main.m): the running program's settings, in its dm/p<N>
        let dir = getenv("DM_APP_DM").map { URL(fileURLWithPath: String(cString: $0)) } ?? Bundle.main.resourceURL?.appendingPathComponent("dm")
        let shortcut = LauncherShortcuts.take()   // the home screen shortcut the app was opened with (main.m), or one chosen before now
        LauncherShortcuts.started = true
        @MainActor func none() -> Bool {   // no settings screen: the game starts
            if let s = shortcut, s != .game { fputs("launcher: shortcut \(s.title): this app has no settings screen; the game starts\n", stderr) }
            return false
        }
        guard let url = dir?.appendingPathComponent("launcher.json"), let data = try? Data(contentsOf: url) else { return none() }
        guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return none() }
        let model = LauncherModel(file.settings)
        model.console = file.console
        model.follow(iosDeviceFacts, on: [.GCControllerDidConnect, .GCControllerDidDisconnect, UIScene.willConnectNotification, UIScene.didDisconnectNotification])
        gameMenuModel = model   // the in-game menu shows and saves the same choices (GameMenu.swift)
        let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
        // Skipped: the saved choices apply as Play would have applied them
        @MainActor func skip(_ why: String) {
            fputs("launcher: \(why)\n", stderr)
            model.applySaved()
            metalDeviceMade = true   // the game starts as soon as this is done, before any refresh, which waits for a later main-actor turn (LauncherModel.follow)
            Task { @MainActor in model.refreshFacts() }   // that turn: the game's device is made by then, so the facts learn MetalFX (mfx:none) for the in-game menu
        }
        // Whether the game syncs its save through a cloud folder: DM_SAVE_SYNC as the game's first save mount will read it, the picked folder put there first (CloudSaves.m; Play
        // and front_ios.m startGame do the same). With it on, a start that would skip the screen for the player shows it for the cloud-save check instead (LauncherShortcuts.swift)
        dm_cloud_saves_env()
        let cloud = LauncherShortcuts.cloudSavesOn(saveSync: getenv("DM_SAVE_SYNC").map { String(cString: $0) })
        // The settings screen already running Play's cloud-save check: the game starts by itself when there is nothing to ask, else the question shows on the screen
        @MainActor func check(_ why: String) {
            fputs("launcher: shown for the cloud-save check (\(why)): the game starts by itself unless the check needs an answer\n", stderr)
            presentLauncher(model, file, dir: dir, on: parent, checkAtStart: true, done: done)
        }
        // main.m's program record, DM_LAUNCHER from an env file or the launch, a home screen shortcut, then the player's Skip this screen next time (LauncherShortcuts.start)
        let (start, notes) = LauncherShortcuts.start(shortcut: shortcut, environment: ProcessInfo.processInfo.environment, skipChosen: UserDefaults.standard.bool(forKey: LauncherModel.skipKey), cloudSaves: cloud)
        for note in notes { fputs(note + "\n", stderr) }
        switch start {
        case .show(let guide): presentLauncher(model, file, dir: dir, on: parent, startWith: guide ? .guide : nil, done: done); return true
        case .skip(let why): skip(why); return false   // no screen, at once
        case .check(let why): check(why); return true
        case .playerSkip: break
        }
        // The player's Skip this screen next time: a controller button held while the app opens asks for the screen. Controllers already paired are listed, and their buttons
        // read, only a moment after this first screen appears, so the check watches for up to 300 ms (only with the skip on: a start with the screen waits for nothing). A Launcher
        // or Guide shortcut chosen meanwhile (LauncherShortcuts.perform keeps it) shows the screen too. Then, with cloud saves on, the screen shows for the cloud-save check
        // (LauncherShortcuts.afterWait)
        LauncherShortcuts.started = false
        Task { @MainActor in
            let held = await LauncherGamepad.heldAtStart(within: .milliseconds(300))
            let late = LauncherShortcuts.take()
            LauncherShortcuts.started = true
            let (after, note) = LauncherShortcuts.afterWait(held: held, late: late, cloudSaves: cloud)
            if let note { fputs(note + "\n", stderr) }
            switch after {
            case .show(let guide): presentLauncher(model, file, dir: dir, on: parent, startWith: guide ? .guide : nil, done: done)
            case .check(let why): check(why)
            case .skip(let why): skip(why); done()
            case .playerSkip: skip("skipped (Skip this screen next time)"); done()   // not an answer afterWait gives
            }
        }
        return true
    }
}

// The settings screen over parent; Play puts the settings into the environment, takes the screen away and calls done (front_ios.m starts the game)
@MainActor private func presentLauncher(_ model: LauncherModel, _ file: SettingsFile, dir: URL?, on parent: UIViewController, startWith: LauncherShortcut? = nil, checkAtStart: Bool = false,
                                         done: @escaping @convention(c) () -> Void) {
    let content = LauncherContent.find(dir: dir, lang: model.values["DM_LANG"] ?? ProcessInfo.processInfo.environment["DM_LANG"])
    let artwork = LauncherArtwork.load(content)
    var host: UIViewController?
    let view = LauncherView(m: model, dir: dir, content: content, artwork: artwork, startWith: startWith, checkAtStart: checkAtStart) {
        guard let h = host else { return }
        host = nil
        LauncherShortcuts.screenUp = false   // a shortcut from now on finds the game running
        model.apply()
        // dismissing ends the view's tasks: its controller polling stops (it sets no handler, so the game's DmGamepad.m finds the controllers as they were). Dismissed from the parent, so
        // a guide or About still over the screen (a Game shortcut plays from there) goes with it: dismissing the screen itself would take away only what it presented
        (h.presentingViewController ?? h).dismiss(animated: false) { done(); metalDeviceMade = true; model.refreshFacts() }   // done() started the game, whose device is made: the facts learn MetalFX now
    }
    let h = DmHostingController(rootView: view)
    h.overrideUserInterfaceStyle = .dark   // the screen is always dark, whatever the device's appearance: pickers and menus too
    h.modalPresentationStyle = .fullScreen
    host = h
    LauncherShortcuts.screenUp = true
    parent.present(h, animated: false)
    fputs("launcher: \(file.settings.count) settings shown\(content.art != nil ? ", with art" : "")\(artwork.logo != nil ? ", logo" : "")\(content.guide != nil ? ", game guide" : "")\(content.manual != nil ? ", manual" : "")\(content.hasAbout ? ", about" : "")\n", stderr)
}
