// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json (an app of several programs: dm/p<N>/launcher.json), which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. All settings share one screen, grouped by section (rows: LauncherRow.swift). Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults shows the defaults, and Play then forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once with the saved choices; DM_SAVED_CHOICES=0 ignores them (and keeps them)
// The look (the NX 18 palette, LauncherRow.swift): the game's key art on the left (dm/art.jpg; without it the app icon, blurred behind and sharp on top), its logo (dm/logo.png) or else its name, the status line, the coral Play pill and,
// when the app has them, Game guide and About this game (GuideViewer.swift); the rails line; the settings on the right as the Gate's system menu (LauncherPanel.swift, NX18-X2.0
// gate-ui.md): the preset chips, quick tiles (Console mode, Game language, Picture; Vitals, Game rumble, Touch controls; mod tiles), the Customize and Cloud saves doors, and their
// pages; Customize ends with Gate at start (launcher.skip, stored inverted: off = the game starts at once, as with DM_LAUNCHER=0; the in-game menu's Settings screen at start turns
// it back on, and a controller button held while the app opens shows the screen anyway, best effort; with cloud saves on, the screen shows for the cloud-save check that Play
// runs, and the game starts by itself when the check has nothing to ask, as it does for the Game shortcut, only with the app in front: LauncherShortcuts.swift)
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



private enum LauncherSheet: Identifiable { case guide, about, acknowledgements; var id: Self { self } }

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
    let screen: Int   // this presentation's number (LauncherShortcuts.screen): a shortcut reaches only the current screen
    let checkAtStart: Bool             // shown for the cloud-save check of a start that skips the screen (Skip this screen next time, the Game shortcut): Play's check runs as it appears
    @State private var content: LauncherContent
    @State private var startTaken = false
    @StateObject private var pad = LauncherGamepad()
    @State private var focus: LauncherFocus? = .play
    @State private var sheet: LauncherSheet?
    @State private var cloudPicking = false
    @State private var stacked = false      // the art above the settings (portrait, a narrow window): the preset chips are below Play then, not beside it (focusMap)
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
    @State private var pages: [GatePage] = []       // the Gate panel's page stack (LauncherPanel.swift): empty is the main page
    @State private var confirming: GateAction?      // Reset all settings or Turn off cloud saves, waiting for the question's answer
    @State private var cardOpen = false             // the NX 18 card over the hero (NX18Card.swift)
    @State private var cardFocus: NX18CardItem = .picture   // the pad's focus inside the card (§20.1: it starts on the picture)
    @StateObject private var profileFlow = NX18ProfileFlow()  // the card's Profile rows and their flows (NX18ProfileFlow.swift)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = LauncherView.arrivedOnce   // the arrival fade has run (once per launch)
    @MainActor static var arrivedOnce = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass   // the NX 18 card's width and scrolling (cardLayer): the space the Gate has, not the device
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    init(m: LauncherModel, dir: URL?, content: LauncherContent, artwork: LauncherArtwork, startWith: LauncherShortcut? = nil, checkAtStart: Bool = false, screen: Int = 0, play: @escaping () -> Void) {
        self.m = m; self.dir = dir; self.artwork = artwork; self.startWith = startWith; self.checkAtStart = checkAtStart; self.screen = screen; self.play = play
        _content = State(initialValue: content)
    }

    private var name: String { (info("CFBundleDisplayName") as? String) ?? (info("CFBundleName") as? String) ?? "Game" }
    private var version: String? { (info("CFBundleShortVersionString") as? String).flatMap { $0.isEmpty ? nil : $0 } }
    private var background: Color { NX18Palette.background(tint: artwork.tint) }   // the art side's: dark in every look
    // About this game's lists (GuideViewer.swift LauncherAboutSheet): the game's languages by name, and what this app offers, from its rows (§18.1, derived)
    private var aboutLanguages: [String] { m.gateRow("DM_LANG")?.options?.map { $0.count > 1 ? $0[1] : $0[0] } ?? [] }
    private var aboutBadges: [String] {
        var b: [String] = []
        if let o = m.gateRow("DM_FPS_TARGET")?.options, o.contains(where: { $0.first == "60" }) { b.append("60 fps") }
        if m.gateRow("DM_UPSCALER") != nil { b.append("MetalFX") }
        if m.gateRow("DM_DYNAMIC_RESOLUTION") != nil { b.append("Auto scaling") }
        if m.gateRow("DM_RUMBLE") != nil { b.append("Rumble") }
        b.append("Touch controls"); b.append("Cloud saves")
        if content.hasGuide { b.append("Game guide") }
        if content.manual != nil { b.append("Manual") }
        return b
    }
    private var pageBackground: Color { NX18PageColor.page(tint: artwork.tint) }      // the look's page, with the art's tint (12 % dark, 6 % light), under the backdrop
    @State private var housingTrailing = false   // the camera housing is on the settings' side (iPhone landscape, top of the phone to the right)
    // From the window scene's orientation: landscape left has the home side on the left, so the top of the phone, and its camera housing, on the right
    private static func housingOnTrailing() -> Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) ??
                UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return true }
        return scene.effectiveGeometry.interfaceOrientation != .landscapeRight
    }
    private var here: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }   // this device in the save questions ("This iPad's save"); the Mac says "Mac"
    private var launcherFromEnv: Bool { LauncherModel.launcherSetByEnv() }   // an env file's or the launch's DM_LAUNCHER, not main.m's for a program record
    private func ring(_ f: LauncherFocus) -> Bool { pad.connected && focus == f && sheet == nil && !cardOpen }   // the card's own focus only while it is open

    var body: some View {
        GeometryReader { g in
            // Side by side whenever the window is clearly landscape and at least 560 pt wide: an iPhone Duo's cover screen in landscape leaves about 590 pt beside its camera, and
            // stacked there (a 466 pt tall screen) the settings had about 200 pt of height under a 250 pt hero. Below about 760 pt the art takes 40 %
            let wide = g.size.width > g.size.height * 1.15 && g.size.width >= 560
            let artShare: CGFloat = g.size.width < 760 ? 0.4 : 0.55   // the settings take 60 % there: at half, "Customize" and "Cloud saves" were cut and the hints wrapped
            let tall = Swift.min(Swift.max(g.size.height * 0.4, 250), 400)
            Group {
                if wide {
                    HStack(spacing: 0) {
                        hero(wide: true, width: (g.size.width * artShare).rounded(), height: g.size.height).frame(width: (g.size.width * artShare).rounded())
                        NX18Rails(flowing: true).ignoresSafeArea(edges: .vertical)
                        // the slab runs to the screen's trailing edge, less the camera housing's inset when it is on that side (iPhone landscape) and a small margin, as at
                        // its top and bottom: the safe area's other side is only the rounded corner, which the slab's own margin clears
                        settings(blend: .leading)
                            .padding(.trailing, housingTrailing ? Swift.max(g.safeAreaInsets.trailing - 6, 4) : 4)
                            .ignoresSafeArea(.container, edges: .trailing)
                    }
                } else {
                    VStack(spacing: 0) {
                        // at least tall, and as tall as its text and buttons need (a large text size, a short window) up to 70 % of the window: they never slide under the settings
                        HeroHeight(least: tall, most: Swift.max(tall, g.size.height * 0.7)) { hero(wide: false, width: g.size.width, height: tall) }
                            .clipped()
                        NX18Rails(axis: .horizontal, flowing: true).ignoresSafeArea(edges: .horizontal)
                        settings(blend: .top)
                    }
                }
            }
            .onChange(of: g.size, initial: true) { m.refreshFacts(); housingTrailing = Self.housingOnTrailing() }   // the window's shape: rotated, or resized under Stage Manager or Split View
            .onChange(of: wide, initial: true) { stacked = !wide }
        }
        .background(pageBackground.ignoresSafeArea())
        // The Gate's arrival (owner, 2026-11-17): once per launch it fades in from the launch screen while settling from 101.5 % to its size, 0.55 s, ease-out; under
        // Reduce Motion a plain 0.3 s fade. Nothing animates after it (the Gate's idle rules, gate-ui §22); a return to the Gate from a game shows it at once
        .opacity(arrived ? 1 : 0)
        .scaleEffect(arrived || reduceMotion ? 1 : 1.015)
        .onAppear {
            guard !arrived else { return }
            if Self.arrivedOnce { arrived = true; return }
            Self.arrivedOnce = true
            withAnimation(reduceMotion ? .easeOut(duration: 0.3) : .easeOut(duration: 0.55)) { arrived = true }
        }
        // The look follows the NX 18 card's Appearance choice through the host's style (NX18Look.swift, DmHostingController.followAppearance); the art side holds itself dark
        .overlay(alignment: .topLeading) { if cardOpen { cardLayer } }
        .nxTextRoot()   // NX 18's UI font for every text below that names no style (NXFont.swift); the guide and About set it again on their own roots
        .tint(GateColor.line)
        .fullScreenCover(isPresented: shown(.guide)) {
            LauncherGuideSheet(content: content, scroller: scroller, closeGlyph: pad.connected ? pad.glyphs.glyph(.b) : nil,
                               turnNames: pad.connected ? (pad.glyphs.name(NXShoulder.l), pad.glyphs.name(NXShoulder.r)) : nil) { sheet = nil }
                .preferredColorScheme(.dark)   // the Guide reader stays dark in every look (gate-ui owner check 5)
        }
        .sheet(isPresented: shown(.about), onDismiss: guideAfterClosing) {
            LauncherAboutSheet(about: content.about ?? LauncherAbout(), artwork: artwork, name: name, version: version, scroller: scroller,
                               closeGlyph: pad.connected ? pad.glyphs.glyph(.b) : nil, languages: aboutLanguages, badges: aboutBadges,
                               lastPlayed: status.lastPlayed, cloudOn: status.cloud != .off, facts: content.facts,
                               preset: m.activePreset.map { ($0.rawValue, $0.title) }) { sheet = nil }
                .presentationBackground(pageBackground)
                .preferredColorScheme(NX18Appearance.current.scheme)   // a sheet does not take the host's style: the look, set again here
        }
        .sheet(isPresented: shown(.acknowledgements), onDismiss: guideAfterClosing) {   // the app's third-party notices (GuideViewer.swift LauncherNoticesSheet)
            LauncherNoticesSheet(tint: artwork.tint, scroller: scroller, closeGlyph: pad.connected ? pad.glyphs.glyph(.b) : nil) { sheet = nil }
                .presentationBackground(pageBackground)
                .preferredColorScheme(NX18Appearance.current.scheme)
        }
        // The controller sentences name the buttons as the pad labels them (pad.glyphs): handle gets Switch buttons by position, so on an Xbox pad Switch B is its A. The shoulders
        // are in the same place on every pad but named differently (LB on an Xbox pad, L1 on a PlayStation pad), and only they answer: the triggers (LT, L2) are ZL and ZR
        .confirmationDialog(SaveSyncReport.chooseTitle, isPresented: isAsking(.choose), titleVisibility: .visible, presenting: report) { r in
            Button(r.localLabel(here: here)) { go(r.localChoice) }
            Button(r.cloudLabel) { go(r.cloudChoice) }
            Button("Cancel", role: .cancel) {}
        } message: { r in Text(r.chooseMessage(here: here) + (pad.connected ? " With a controller: \(pad.glyphs.name(NXShoulder.l)) plays this \(here)'s, \(pad.glyphs.name(NXShoulder.r)) the cloud's, \(pad.glyphs.name(.b)) cancels." : "")) }
        .confirmationDialog(SaveSyncReport.unreadableTitle, isPresented: isAsking(.unreadable), titleVisibility: .visible, presenting: report) { r in
            Button("Play This \(here)'s Save") { go("offline") }   // the mount does not wait for the cloud again
            Button("Try Again") { DispatchQueue.main.async { start() } }
            Button("Cancel", role: .cancel) {}
        } message: { r in Text(r.unreadableMessage(here: here) + (pad.connected ? " With a controller: \(pad.glyphs.name(.a)) plays this \(here)'s save, \(pad.glyphs.name(.y)) tries again, \(pad.glyphs.name(.b)) cancels." : "")) }
        .task { await pad.run { handle($0) } }
        .onChange(of: focus) { NX18RailsIdle.pulse() }   // a touch or a pad move: the rails run one more cycle (GW19)
        .task { await followStatus() }
        .onChange(of: sheet) {          // a button held as a sheet opens or closes (A held while B closes the guide) is no press on what is under it
            pad.holdUntilReleased()
            if sheet != nil { stopAutoStart("the guide, About this game or Acknowledgements opened") }
        }
        .onChange(of: cloudPicking) { pad.holdUntilReleased(); if cloudPicking { stopAutoStart("the cloud-save folder picker opened") } }
        .onChange(of: asking) { pad.holdUntilReleased() }        // the press that answered a save question is no press on the settings
        .onReceive(LauncherShortcuts.requests) { if screen == LauncherShortcuts.screen { shortcut($0) } }   // a home screen shortcut chosen while the screen is up, for this screen only
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in startHeld() }   // back in front: a held start goes
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in startHeld() }   // came first in the iOS 27.3 Simulator, the application still inactive, and the application's then started it: this one is for an application that stays active (a TV's scene, not tried)
        .onAppear {
            NX18Profile.shared.lookAtFolder()   // the NX 18 folder's Profile at Gate open: a cheap look within 1 s (§20.5)
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
            Button { openCard() } label: {
                NX18Mark(height: 24)
                    .background { if artwork.art != nil { NX18MarkShade(strong: reduceTransparency) } }   // over art only: the plain backdrop is dark already
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading).contentShape(Rectangle())   // a 44 pt target (G12)
            }
            .buttonStyle(NX18PressStyle())
            .nx18Focus(ring(.mark), cornerRadius: 8)
            .accessibilityLabel("NX 18").accessibilityHint("Opens the NX 18 card: the version and Appearance")
            .padding(.top, -10)
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
                LauncherStatusLine(status: gateStatus, color: NX18Palette.onArt).padding(.top, 5)
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
        .environment(\.colorScheme, .dark)   // the art side stays dark in every look: art, scrim, title, status line, Play, Guide, About and the mark (§11a.2)
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
    // Glass on the hero buttons only over art, and solid while the NX 18 card is open over them (GW26)
    private var heroGlass: Bool { artwork.art != nil && !cardOpen }
    private var actions: some View {
        GlassEffectContainer(spacing: 4) { actionsLaidOut }   // one container: below the 10 pt gap, so the buttons never merge
    }
    private var actionsLaidOut: some View {
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
            .nx18Surface(Capsule(), fill: NX18Palette.coral, hairline: .clear, tint: Color(nx18: 0xF48875), interactive: true, art: heroGlass)   // faint coral glass over art (§11)
            .contentShape(Capsule())
        }
        .buttonStyle(NX18HeroButtonStyle())
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
        setenv("DM_PLAY_AT", String(format: "%.6f", Date().timeIntervalSince1970), 1)   // Play: the start's timeline counts from here, the cloud-save check in it (dm/host/hle_lifecycle.c)
        check += 1; checking = true; asking = nil; held = nil   // a held answer is old: this Play checks again
        let mine = check
        dm_cloud_saves_env()   // DM_SAVE_SYNC from the picked folder, as the game's mount will read it (front_ios.m calls it again at the start)
        dm_profile_env()       // the Profile's name and picture for the games (NX18Profile.swift); an env.txt value wins
        setenv("DM_PLAY_PRESET", m.activePreset?.rawValue ?? "custom", 1)   // the play record's preset for this session (PlayRecord.swift)
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
    // The NX 18 card: under the mark, over the hero; a tap outside only closes it (it never reaches what is under it), and focus goes back to the mark
    private func openCard() {
        stopAutoStart("the NX 18 card opened")
        cardFocus = .picture; cardOpen = true; profileFlow.strip = nil; profileFlow.note = nil
        NX18Profile.shared.refreshFolderState()
        if pad.connected { focus = .mark }
        pad.holdUntilReleased()
    }
    private func closeCard() { cardOpen = false; if pad.connected { focus = .mark }; pad.holdUntilReleased() }
    private var cardLayer: some View {
        GeometryReader { g in
            let wide = g.size.width > g.size.height * 1.15 && g.size.width >= 640
            let w: CGFloat = horizontalSizeClass == .regular && verticalSizeClass == .regular ? 360 : wide ? 320 : g.size.width - 32   // §20.1: room on both axes (an iPad, an open iPhone Duo) by size class, not the device
            ZStack(alignment: .topLeading) {
                // the Gate behind goes soft, as under a console's quick menu: the system's thin material (the compositor's blur, no work of ours per frame), and a light dim
                // over it so the card stands out (owner, 2026-11-16); both go when the card closes
                ZStack { Rectangle().fill(.ultraThinMaterial); Color.black.opacity(0.15) }
                    .ignoresSafeArea().contentShape(Rectangle()).onTapGesture { closeCard() }
                    .accessibilityLabel("Close the NX 18 card").accessibilityAddTraits(.isButton)
                NX18Card(gameVersion: version, focused: pad.connected ? cardFocus : nil, glyphs: pad.connected ? pad.glyphs : nil, close: { closeCard() }, art: artwork.art != nil,
                         profileRows: cardProfileRows, scrolls: wide && verticalSizeClass == .compact)   // short of height (iPhone landscape): the body scrolls
                    .frame(width: w)
                    .frame(maxHeight: g.size.height - 58 - 21, alignment: .top)   // §20.1: in iPhone landscape the body scrolls under the fixed header
                    .padding(.leading, 16).padding(.top, 58)
            }
        }
        .transition(.opacity)
        .nx18ProfileFlow(profileFlow)
    }
    private var cardProfileRows: NX18CardProfile {
        let f = profileFlow, padOn = pad.connected
        return NX18CardProfile(busy: f.busy, note: f.note, strip: padOn ? f.strip : nil, shared: f.cloudShared, capturesShared: f.capturesShared,
                               choosePicture: { f.choosePicture(pad: false) }, editName: { f.editName(pad: false) },
                               toggle: { f.toggleProfile() }, chooseFolder: { f.chooseFolder(pad: false) }, saves: { f.savesTapped() },
                               captures: { f.capturesTapped() })
    }
    // The card's pad order (§20.1), as it reads top to bottom: ✕, the picture, name, the switch, the folder and saves rows while the switch is on, then Appearance
    private var cardOrder: [NX18CardItem] {
        var o: [NX18CardItem] = [.close, .picture, .name, .profile]
        if NX18Profile.shared.enabled {
            o.append(.folder)
            if case .chosen = NX18Profile.shared.folderState { o.append(contentsOf: [.saves, .captures]) }
        }
        o.append(.appearance)
        return o
    }

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
        smallButton("About this game", short: "About", icon: "info.circle", label: l, focus: .about) { sheet = .about }   // always: On NX 18 and Your play always have content (§18)
    }
    // pad: the controller button that presses it from anywhere on the screen (Y: the guide), its glyph at the end of a named button while a controller is connected
    private func smallButton(_ title: String, short: String, icon: String, label: ButtonLabel, focus f: LauncherFocus, pad button: NXButton? = nil,
                             action: @escaping () -> Void) -> some View {
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
            .nx18Surface(Capsule(), fill: NX18Palette.row, hairline: NX18Palette.separator, tint: NX18Palette.charcoal.opacity(0.25), art: heroGlass)   // faint glass over art (§11)
            .contentShape(Capsule())
        }
        .buttonStyle(NX18HeroButtonStyle())
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

    // The Gate's system menu (LauncherPanel.swift): the slab with its pages, beside the art (or under it, stacked)
    private func settings(blend: Edge) -> some View {
        GatePanel(m: m, pages: $pages, focus: focus, padShown: pad.connected && sheet == nil && !cloudPicking && !cardOpen, quiet: cardOpen, glyphs: pad.glyphs, status: status.cloud,
                  gateAtStartLocked: launcherFromEnv, footer: AnyView(panelFooter), acknowledgements: LauncherNotices.available,
                  touched: { focus = $0 }, act: gateAct)
            .background { LauncherBackdrop(wash: artwork.wash, page: pageBackground, edge: background, blend: blend).ignoresSafeArea() }
            .sheet(isPresented: $cloudPicking, onDismiss: guideAfterClosing) {
                DocumentPicker(types: [.folder]) { url in
                    cloudPicking = false
                    if dm_store_cloud_saves(url) {
                        fputs("launcher: cloud saves folder chosen\n", stderr)
                        if dm_nx18_cloud_shared() { dm_set_nx18_cloud_shared(false); profileFlow.cloudShared = false }   // a folder picked here is this game's own: its saves leave the NX 18 folder
                    }
                    else { fputs("launcher: cloud saves folder could not be remembered\n", stderr) }
                    refreshCloud()
                } onCancel: { cloudPicking = false }
            }
            .alert(confirming == .confirmReset ? "Reset all settings?" : "Turn off cloud saves?", isPresented: confirmShown) {
                Button(confirming == .confirmReset ? "Reset" : "Turn Off", role: .destructive) { confirmYes() }
                Button("Cancel", role: .cancel) { confirming = nil }
            } message: {
                let what = confirming == .confirmReset ? "Every setting goes back to the values this game was tested with. Gate at start and cloud saves stay as they are."
                                                       : "This device keeps its own save. Your other devices keep theirs."
                Text(verbatim: what + (pad.connected ? " With a controller: \(pad.glyphs.name(.a)) confirms, \(pad.glyphs.name(.b)) cancels." : ""))   // one string: Text's + is deprecated in iOS 26
            }
    }
    private var panelFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let v = version { Text("Version \(v)") }
            if let n = nx18Line { Text(verbatim: n) }
            Text(NX18Credits.buttonIcons)
        }
    }
    private var confirmShown: Binding<Bool> { Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }) }
    private func confirmYes() {
        switch confirming {
        case .confirmReset?: if m.changed { m.reset() }
        case .confirmCloudOff?:
            if dm_nx18_cloud_shared() { dm_set_nx18_cloud_shared(false); profileFlow.cloudShared = false }   // off means off: not in the NX 18 folder either
            dm_clear_cloud_saves(); refreshCloud(); fputs("launcher: cloud saves turned off\n", stderr)
        default: break
        }
        confirming = nil
    }
    private func gateAct(_ a: GateAction) {
        switch a {
        case .chooseCloudFolder: cloudPicking = true
        case .confirmReset, .confirmCloudOff: confirming = a
        case .acknowledgements: if LauncherNotices.available { sheet = .acknowledgements }
        }
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
        refreshCloud()   // free memory left the line with the Gate panel (gate-ui O4), and its 2-second refresh with it
    }
    // The Gate's status line (gate-ui O4): only the console and the preset state; last played and cloud saves live in About this game › Your play
    private var gateStatus: LauncherStatus {
        var s = LauncherStatus()
        s.console = status.console
        s.preset = m.hasPresets ? m.presetLabel : nil
        return s
    }
    // This game's cloud-save folder as the start uses it (CloudSaves.m dm_cloud_saves_env): the NX 18 folder while the Profile shares this game's saves there, else the game's own
    // folder. The status and the Cloud saves page read only the own folder before, so a game whose saves went to the NX 18 folder (the Profile's Connect or Create) showed Off
    private func refreshCloud() { status.cloud = dmCloudFolderName() != nil ? .on : .off }

    // MARK: The controller (LauncherController.swift)

    // The focus lines of the page the panel shows (gate-ui §8 LauncherFocusMap): on the main page Play's line, the presets, Back to Balanced while the values match no
    // preset, the first tile row, the two doors, the second tile row and the mod tiles; on a page its back button, then its rows, one a line
    private var focusMap: LauncherFocusMap {
        var lines: [[LauncherFocus]] = []
        switch pages.last ?? .main {
        case .main:
            var top: [LauncherFocus] = [.play]
            if content.hasGuide { top.append(.guide) }
            top.append(.about)
            lines.append([.mark])   // the NX 18 mark above Play (G12)
            lines.append(top)
            if m.hasPresets {
                let chips = m.offeredPresets.map { LauncherFocus.preset($0) }
                let cols = stackedChips ? 2 : chips.count
                lines += stride(from: 0, to: chips.count, by: cols).map { Array(chips[$0..<Swift.min($0 + cols, chips.count)]) }
                if m.activePreset == nil { lines.append([.backToPreset]) }
            }
            for row in [m.gateFirstTiles, m.gateSecondTiles, m.gateModTiles] where !row.isEmpty {
                lines.append(row.map { LauncherFocus.tile($0) })
                if row == m.gateFirstTiles { lines.append([.door("customize"), .door("cloud")]) }   // the doors sit between the tile rows (G10)
            }
            if m.gateFirstTiles.isEmpty { lines.insert([.door("customize"), .door("cloud")], at: lines.count - [m.gateSecondTiles, m.gateModTiles].filter { !$0.isEmpty }.count) }
        case .customize:
            lines.append([.pageBack])
            for g in m.gateCustomizeGroups {
                lines += g.rows.map { [LauncherFocus.row($0.env)] }
                if g.title == "Other choices" { lines.append([.action("gate")]); if LauncherNotices.available { lines.append([.acknowledgements]) } }
            }
            if !m.gateCustomizeGroups.contains(where: { $0.title == "Other choices" }) {
                lines.append([.action("gate")]); if LauncherNotices.available { lines.append([.acknowledgements]) }
            }
            lines.append([.reset])
        case .cloud:
            lines += [[.pageBack], [.action("cloud.choose")]]
            if status.cloud != .off { lines.append([.action("cloud.off")]) }
        case .touch:
            lines.append([.pageBack]); lines += m.gateTouchRows.map { [LauncherFocus.row($0.env)] }
        case .options(let env):
            lines.append([.pageBack]); lines += (m.gateRow(env)?.options ?? []).map { [LauncherFocus.option(env, $0[0])] }
        }
        return LauncherFocusMap(lines: lines)
    }
    @Environment(\.dynamicTypeSize) private var typeSize
    private var stackedChips: Bool { typeSize >= .xxLarge }   // the panel's 2 × 2 (and one column) chips: two a line for the controller too

    private func handle(_ e: LauncherPadEvent) {
        if cardOpen {   // the NX 18 card: up / down between ✕ and Appearance, left / right step Appearance, A presses, B closes; L / R wait until it closes (§20.1)
            switch e {
            case .up, .down:
                let o = cardOrder, i = o.firstIndex(of: cardFocus) ?? (o.firstIndex(of: .picture) ?? 0)
                cardFocus = o[max(0, min(o.count - 1, i + (e == .down ? 1 : -1)))]; profileFlow.strip = nil
            case .left, .right: if cardFocus == .appearance { NX18Appearance.current = NX18Appearance.current.stepped(e == .right ? 1 : -1) }   // no swipe-step on the saves row (§20.2)
            case .a:
                switch cardFocus {
                case .close: closeCard()
                case .appearance: NX18Appearance.current = NX18Appearance.current.stepped(1)
                case .picture: profileFlow.choosePicture(pad: true)
                case .name: profileFlow.editName(pad: true)
                case .profile: profileFlow.toggleProfile()
                case .folder: profileFlow.chooseFolder(pad: true)
                case .saves: profileFlow.savesTapped()
                case .captures: profileFlow.capturesTapped()
                }
            case .b: closeCard()
            default: break
            }
            return
        }
        if let open = sheet {   // a viewer is up: what it takes itself (the guide's page: every button but ZL / ZR, GuideViewer.swift), else B closes it, up / down scroll, L / R switch between the guide and the manual
            if scroller.pad?(e) == true { return }
            switch e {
            case .b: sheet = nil
            case .up: scroller.scroll?(-160)
            case .down: scroller.scroll?(160)
            case .l, .left: if open == .guide || open == .about { scroller.page?(-1) } else if open == .acknowledgements { scroller.scroll?(-600) }   // About: the section before   // the notices: L / R a screenful
            case .r, .right: if open == .guide || open == .about { scroller.page?(1) } else if open == .acknowledgements { scroller.scroll?(600) }
            default: break
            }
            return
        }
        if cloudPicking { if e == .b { cloudPicking = false }; return }   // the system's folder picker, which a controller cannot drive: B closes it, as the Launcher and Guide shortcuts do (the B held is no press on the settings: onChange of cloudPicking)
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
        if let c = confirming {   // Reset all settings or Turn off cloud saves asks first: A confirms, B cancels
            if e == .a { confirming = c; confirmYes() } else if e == .b { confirming = nil }
            return
        }
        // L and R step the drawn presets with wrap from anywhere; X is Undo while a preset change's toast shows, else goes back to the base preset while Custom (presets-first W9)
        if m.hasPresets, e == .l || e == .r { m.stepPreset(e == .r ? 1 : -1); return }
        if e == .x { if m.undoState != nil { m.undo() } else if m.isCustom { m.backToBase() }; return }
        let map = focusMap
        // An item no longer drawn (a page changed by touch, Back to Balanced gone): the page's first item, or Play on the main page
        let cur = focus.flatMap { map.contains($0) ? $0 : nil } ?? (pages.isEmpty ? .play : map.lines.first?.first ?? .play)
        if focus != cur { focus = cur }
        switch e {
        case .up, .down: focus = map.vertical(cur, e == .down ? 1 : -1)
        case .left, .right:
            let d = e == .right ? 1 : -1
            // Left and right only move: a tile changes with A alone (owner, 2026-11-17), and left from the slab's first column goes over to the hero's About this game
            // (side by side; stacked, nothing is to its left). A list row on a page keeps its ‹ › step
            if let f = map.horizontal(cur, d) { focus = f }
            else if case .row(let env) = cur, let s = m.gateRow(env) { m.advance(s, by: d) }
            else if case .tile = cur, d < 0, !stacked { focus = .about }
        case .a: activate(cur)
        case .b:   // back a page (focus returns to what opened it), or on the main page to Play
            if let p = pages.popLast() {
                switch p {
                case .customize: focus = .door("customize")
                case .cloud: focus = .door("cloud")
                case .touch: focus = .tile("touch")
                case .options(let env): focus = pages.last == nil ? .tile(env) : .row(env)
                case .main: focus = .play
                }
            } else { focus = .play }
        case .plus: start()
        case .y: openGuide()
        case .x, .minus, .l, .r, .zl, .zr: break
        }
    }

    private func activate(_ f: LauncherFocus) {
        switch f {
        case .preset(let p): m.applyPreset(p)
        case .play: start()
        case .guide: openGuide()
        case .about: sheet = .about
        case .mark: openCard()
        case .card: break   // the card's own items: NX18Card handles them (handle)
        case .backToPreset: m.backToBase()
        case .door("customize"): pages.append(.customize); focus = .pageBack
        case .door("cloud"): pages.append(.cloud); focus = .pageBack
        case .door: break
        case .tile("touch"): pages.append(.touch); focus = .pageBack
        case .tile(let env), .row(let env):
            guard let s = m.gateRow(env), m.editable(s) else { return }
            if s.kind == "choice", (s.options?.count ?? 0) >= 3 { pages.append(.options(env)); focus = .option(env, m.shown(s)) }
            else if s.kind != "range" { m.advance(s, by: 1) }
        case .option(let env, let v):
            guard let s = m.gateRow(env), m.canPick(s, v), !m.fixed.contains(env) else { return }
            m.pick(s, v); pages.removeLast(); focus = pages.isEmpty ? .tile(env) : .row(env)
        case .action("gate"): if !launcherFromEnv { m.skipAtStart.toggle() }
        case .action("cloud.choose"): cloudPicking = true
        case .action("cloud.off"): confirming = .confirmCloudOff
        case .action: break
        case .pageBack: handle(.b)
        case .reset: if m.changed { confirming = .confirmReset }
        case .acknowledgements: if LauncherNotices.available { sheet = .acknowledgements }
        }
    }
}

// Shows the launcher over the root view controller and calls done once the settings are in the environment; false (done is not called) when there is no launcher, or when it is
// skipped. True also while the player's own skip waits a moment for a held controller button: done is then called (the game starts) without the screen, or the screen shows. With
// cloud saves on, a skip the player chose (Skip this screen next time, the Game shortcut) returns true and shows the screen running the cloud-save check, which calls done itself
// when there is nothing to ask
// The first-start acknowledgement (NX18Welcome.swift, gate-ui §21.2a) comes first when it is due, before launcher.json is read, so an app with no Gate and every skipped start ask
// too: its panel shows, true is returned, and after I understand the start goes on as it would have (gateStart), done called at once when that start has no screen
@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    nonisolated(unsafe) let viewController = viewController, done = done   // a raw pointer and a C callback: not Sendable, but front_ios.m hands them over on the main thread, where they stay
    return MainActor.assumeIsolated {
        guard NX18Acknowledge.due() else { return gateStart(viewController, done) }
        let dir = getenv("DM_APP_DM").map { URL(fileURLWithPath: String(cString: $0)) } ?? Bundle.main.resourceURL?.appendingPathComponent("dm")
        let content = LauncherContent.find(dir: dir, lang: ProcessInfo.processInfo.environment["DM_LANG"])
        let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
        NX18Acknowledge.present(on: parent, artwork: LauncherArtwork.load(content)) {
            if !gateStart(viewController, done) { done() }
        }
        return true
    }
}
@MainActor private func gateStart(_ viewController: UnsafeMutableRawPointer, _ done: @escaping @convention(c) () -> Void) -> Bool {
    nonisolated(unsafe) let viewController = viewController
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
        model.takeList(file)   // the console, the drawn presets and their moves, then the stored base preset
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
                                         welcomed: Bool = false, done: @escaping @convention(c) () -> Void) {
    let content = LauncherContent.find(dir: dir, lang: model.values["DM_LANG"] ?? ProcessInfo.processInfo.environment["DM_LANG"])
    let artwork = LauncherArtwork.load(content)
    // The welcome (NX18Welcome.swift, gate-ui §21.1): on the first Gate of this app, before the Gate is built; not for the skipped start's cloud-save check, nor a shortcut's guide
    if !welcomed, !checkAtStart, startWith == nil, NX18WelcomeGate.due() {
        NX18WelcomeGate.present(on: parent, artwork: artwork) {
            presentLauncher(model, file, dir: dir, on: parent, startWith: startWith, checkAtStart: checkAtStart, welcomed: true, done: done)
        }
        return
    }
    // Weak: the view holds this closure and the hosting controller holds the view, so a strong hold would keep the screen, its art and its controller poll alive whenever it goes
    // without Play (Play sets it to nil before it dismisses). While the screen is up its presenter holds it
    weak var host: UIViewController?
    LauncherShortcuts.screen += 1
    let view = LauncherView(m: model, dir: dir, content: content, artwork: artwork, startWith: startWith, checkAtStart: checkAtStart, screen: LauncherShortcuts.screen) {
        guard let h = host else { return }
        host = nil
        LauncherShortcuts.screenUp = false   // a shortcut from now on finds the game running
        model.apply()
        // dismissing ends the view's tasks: its controller polling stops (it sets no handler, so the game's DmGamepad.m finds the controllers as they were). Dismissed from the parent, so
        // a guide or About still over the screen (a Game shortcut plays from there) goes with it: dismissing the screen itself would take away only what it presented
        (h.presentingViewController ?? h).dismiss(animated: false) { done(); metalDeviceMade = true; model.refreshFacts() }   // done() started the game, whose device is made: the facts learn MetalFX now
    }
    let h = DmHostingController(rootView: view)
    h.followAppearance()   // the look the NX 18 card's Appearance asks for (Match device by default): the screen, its sheets, pickers and menus; the art side holds itself dark
    h.modalPresentationStyle = .fullScreen
    host = h
    LauncherShortcuts.screenUp = true
    parent.present(h, animated: false)
    fputs("launcher: \(file.settings.count) settings shown\(content.art != nil ? ", with art" : "")\(artwork.logo != nil ? ", logo" : "")\(content.guide != nil ? ", game guide" : "")\(content.manual != nil ? ", manual" : "")\(content.hasAbout ? ", about" : "")\n", stderr)
}

// The page behind the settings slab: the art's colours (LauncherArtwork.wash, made once, 48 × 27 and blurred) drawn scaled up as a soft multi-colour gradient, under the look's
// page colour so it stays calm (more page in light, so the opaque slab's text keeps its contrast), fading into the art side's colour at the edge it meets (the divider), so the
// two read as one backdrop. Static: an image and two fills, nothing that animates or redraws per frame (the Gate's idle rules, gate-ui §22)
struct LauncherBackdrop: View {
    let wash: UIImage?
    let page: Color
    let edge: Color      // the art side's background (dark in every look)
    let blend: Edge      // the side that meets the art: leading beside it, top under it
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        ZStack {
            page
            if let wash {
                Image(uiImage: wash).resizable().interpolation(.high).opacity(dark ? 0.62 : 0.34)
                page.opacity(dark ? 0.38 : 0.5)
            }
            if dark {
                LinearGradient(stops: [.init(color: edge, location: 0), .init(color: edge.opacity(0), location: 0.35)],
                               startPoint: blend == .top ? .top : .leading, endPoint: blend == .top ? .bottom : .trailing)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

#if os(iOS)
/// The folder this game's cloud saves go through, by name, or nil when they are off: the NX 18 folder while the Profile shares this game's saves there
/// (dm_nx18_cloud_shared, the card's This game's saves), else the game's own folder (the Cloud saves page). As CloudSaves.m dm_cloud_saves_env picks it at the start
func dmCloudFolderName() -> String? {
    if dm_nx18_cloud_shared(), let f = NX18Profile.folderURL() { return "\(f.lastPathComponent) (NX 18 folder)" }
    return dm_cloud_saves_path(nil).map { ($0 as NSString).lastPathComponent }
}
#endif
