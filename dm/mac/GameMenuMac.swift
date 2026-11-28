// The in-game menu in the Mac's game app (the host, dmhost: dm/host/Makefile links this file with the iOS menu's GameMenu.swift and GameMenuPanel.swift and the launcher's model).
// The same panel as the iPhone's, over the game's view in an NSHostingView: the rows the running game takes at once (front_mac.m dm_setting_live), the presets, Cheats and More
// (Take Screenshot, Gate at start, Show log, Quit). The controller's Home, Escape and the app menu's Game Menu… (⌘,) open it (front_mac.m); the game keeps running and gets no
// input while it is up. Its text is the Mac's text styles scaled with the window (gameMenuMacScale), so it reads as on the iPhone in a window and in full screen.
// The settings' model is made at the first opening from the app's Resources/dm/launcher.json, as the settings window makes its own (Launcher.swift): the saved choices, which a
// pick saves as the window does, so the window and Beam show it at the next start. No launcher.json (an app packed without settings): the menu has Cheats and More only
import AppKit
import CoreHaptics
import GameController
import Metal
import MetalFX
import SwiftUI

// The panel's controller and keyboard (GameMenuPanel.swift's GameMenuPad on the Mac). No polling: front_mac.m hands over the GM_* bits held (dm/host/game_menu_input.h) whenever a
// controller or a key changes while the panel is up (dm_mac_game_menu_input), and this turns them into the panel's moves: a press acts once, a held direction repeats (a timer
// only while one is held). Bits held when the panel opened count only once released. connected: a controller is there (the ring and the button hints show)
@MainActor final class GameMenuMacPad: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var glyphs = NXPadGlyphs()
    static weak var active: GameMenuMacPad?
    static var heldAtOpen: UInt32 = 0
    private var handle: ((LauncherPadEvent) -> Void)?
    private var held: UInt32 = 0
    private var blocked: UInt32 = 0
    private var repeatTask: Task<Void, Never>?
    private static let order: [LauncherPadEvent] = [.up, .down, .left, .right, .a, .b, .x, .y, .plus, .minus, .l, .r, .zl, .zr]   // the GM_* bits' order
    private static let directions: UInt32 = 0xF

    init() { refreshPads() }

    func refreshPads() {
        let first = GCController.controllers().first { $0.extendedGamepad != nil }
        let any = first != nil || dm_mac_pads_any()
        if connected != any { connected = any }
        let g = NXPadGlyphs.of(first)
        if glyphs != g { glyphs = g }
    }

    // While the panel is up (its view's task): events go to handle; the task ends with the panel
    func run(_ handle: @escaping @MainActor (LauncherPadEvent) -> Void) async {
        self.handle = handle
        blocked = Self.heldAtOpen; held = Self.heldAtOpen
        Self.active = self
        let names: [Notification.Name] = [.GCControllerDidConnect, .GCControllerDidDisconnect]
        let observers = names.map { NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { _ in MainActor.assumeIsolated { GameMenuMacPad.active?.refreshPads() } } }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }   // the sleep ends at the cancel: nothing runs meanwhile
        observers.forEach(NotificationCenter.default.removeObserver)
        repeatTask?.cancel(); repeatTask = nil
        self.handle = nil
        if Self.active === self { Self.active = nil }
    }

    func input(_ bits: UInt32) {
        let pressed = bits & ~held & ~blocked
        blocked &= bits   // a bit held at the opening counts once it was released
        held = bits
        if bits != 0 && !connected { refreshPads() }   // a raw HID pad that GameController does not list
        for (i, e) in Self.order.enumerated() where pressed & (1 << UInt32(i)) != 0 { handle?(e) }
        let dir = bits & Self.directions & ~blocked
        if dir == 0 { repeatTask?.cancel(); repeatTask = nil; return }
        if pressed & Self.directions != 0 || repeatTask == nil {
            repeatTask?.cancel()
            repeatTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                while !Task.isCancelled, let self {
                    let d = self.held & Self.directions & ~self.blocked
                    guard d != 0 else { return }
                    for (i, e) in Self.order.prefix(4).enumerated() where d & (1 << UInt32(i)) != 0 { self.handle?(e) }
                    try? await Task.sleep(for: .milliseconds(110))
                }
            }
        }
    }
}

// The panel's size on the Mac: its text styles are the Mac's (10 pt notes, NXFont.base), so the panel is laid out smaller and drawn larger, about the iPhone's size in a 720-point
// window and larger in a full screen; the clicks follow the scale
func gameMenuMacScale(_ size: CGSize) -> CGFloat { max(1.25, min(2.2, size.height / 560)) }

// Manual & documents' viewer (GameDocumentsViewer.swift) goes over the scaled panel at the window's own size, so the pages, the guide and the pictures stay sharp: only its
// header is drawn larger (chrome), as the panel's text is
struct GameMenuMacRoot: View {
    @ObservedObject var model: GameMenuPanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geo in
            let s = gameMenuMacScale(geo.size)
            ZStack(alignment: .topLeading) {
                GameMenuPanelView(model: model)
                    .frame(width: geo.size.width / s, height: geo.size.height / s)
                    .scaleEffect(s, anchor: .topLeading)
                if let open = model.document, !model.leaving {
                    GameDocumentViewer(model: model, control: model.documentControl, open: open, chrome: s)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.document?.doc.id)
        }
    }
}

// The panel over the game's view: added to the window's content view, above the Metal layer, resized with it; opened and closed with GameMenuPanelView's own fade
@MainActor final class GameMenuMacHost {
    let model: GameMenuPanelModel
    let view: NSHostingView<GameMenuMacRoot>
    private var closing = false
    init(model: GameMenuPanelModel) {
        self.model = model
        view = NSHostingView(rootView: GameMenuMacRoot(model: model))
        view.appearance = NX18Appearance.current.appearance   // the look the NX 18 card chose (nil follows the Mac)
    }
    func show(in parent: NSView) {
        view.frame = parent.bounds
        view.autoresizingMask = [.width, .height]
        parent.addSubview(view)
        NSAccessibility.post(element: view, notification: .layoutChanged)
    }
    func hide() {
        guard !closing else { return }
        closing = true
        withAnimation(.easeIn(duration: 0.12)) { model.leaving = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [view] in
            view.removeFromSuperview()
            NSAccessibility.post(element: NSApp as Any, notification: .layoutChanged)
        }
    }
}

@MainActor private var gameMenuMac: GameMenuMacHost?
@MainActor private var gameMenuMacLoaded = false

// The device facts the rules are decided on, as the settings window's macDeviceFacts gives them (dm/mac/Launcher.swift, which the host does not build): the fastest screen,
// haptics, controllers, MetalFX, GPU capture. No TV and no window shape: nothing on the Mac stretches the picture
@MainActor func gameMenuMacFacts() -> DeviceFacts {
    var f = DeviceFacts()
    f.kind = .mac
    f.hz = NSScreen.screens.map(\.maximumFramesPerSecond).max()
    f.haptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    f.controller = !GCController.controllers().isEmpty || dm_mac_pads_any()
    f.tv = false
    if let dev = MTLCreateSystemDefaultDevice() { f.metalFX = MTLFXSpatialScalerDescriptor.supportsMetal4FX(dev) }   // the game's own device: Metal returns the same one
    f.gpuCapture = MTLCaptureManager.shared().supportsDestination(.gpuTraceDocument)
    return f
}

// The settings' model, once: launcher.json and the saved choices, decided on this Mac (gameMenuMacFacts: its screens, controllers, MetalFX)
@MainActor private func gameMenuMacModel() {
    guard !gameMenuMacLoaded else { return }
    gameMenuMacLoaded = true
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json"), let data = try? Data(contentsOf: url),
          let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else {
        fputs("in-game menu: no launcher.json: Cheats and More only\n", stderr); return
    }
    let model = LauncherModel(file.settings)
    model.takeList(file)
    model.follow(gameMenuMacFacts, on: [.GCControllerDidConnect, .GCControllerDidDisconnect, NSApplication.didChangeScreenParametersNotification])
    gameMenuModel = model
}

@MainActor private func gameMenuMacClose() {
    guard let host = gameMenuMac else { return }
    gameMenuMac = nil
    host.model.closed = true
    dm_gamepad_panel_closed()   // front_mac.m: the game has its input back once nothing is held
    host.hide()
}

// front_mac.m: open the panel over the game's view (a window's content view) with the GM_* bits held now; false when it is open already
@_cdecl("dm_mac_game_menu_open")
public func dmMacGameMenuOpen(_ view: UnsafeMutableRawPointer, _ held: UInt32) -> Bool {
    nonisolated(unsafe) let view = view
    return MainActor.assumeIsolated {
        if gameMenuMac != nil { return false }
        gameMenuMacModel()
        let parent = Unmanaged<NSView>.fromOpaque(view).takeUnretainedValue()
        GameMenuMacPad.heldAtOpen = held
        let model = GameMenuPanelModel(anchor: parent)
        let host = GameMenuMacHost(model: model)
        model.close = { gameMenuMacClose() }
        gameMenuMac = host
        host.show(in: parent)
        return true
    }
}

@_cdecl("dm_mac_game_menu_close")
public func dmMacGameMenuClose() { MainActor.assumeIsolated { gameMenuMacClose() } }

// front_mac.m: the GM_* bits held now on every controller and the keyboard, at each change while the panel is up
@_cdecl("dm_mac_game_menu_input")
public func dmMacGameMenuInput(_ bits: UInt32) { MainActor.assumeIsolated { GameMenuMacPad.active?.input(bits) } }

// LauncherPanel.swift (built in for the panel's shared pieces: GateRing, GateText, NX18Icon) names the cloud folder on its Cloud saves page, which the host never draws: the
// settings window's MacCloud (dm/mac/Launcher.swift) is not built in, so this stands in for it, as Beam's Shims.swift does
@MainActor enum MacCloud {
    static var folderName: String? {
        let f = UserDefaults.standard.string(forKey: "cloudSaves.folder") ?? ""
        return f.isEmpty ? nil : (f as NSString).lastPathComponent
    }
}
