// What NX 18's shared UI files expect from the app that compiles them. The Mac launcher's Launcher.swift has the real ones; Beam stands in for them here.
import CoreHaptics
import AppKit
import Foundation
import GameController
import Metal
import MetalFX

@MainActor enum MacCloud {   // LauncherPanel's Cloud saves page names the folder: the game's whose settings Beam shows (GameSettingsView sets defaults), its own or the NX 18 folder
    static var defaults: UserDefaults = .standard
    static var folderName: String? { NX18CloudSaves.place(defaults, nx18: ProfileSetup.connectedFolder()).folder.map { ($0 as NSString).lastPathComponent } }
}

extension NX18CloudSaves {
    /// A built Mac app's cloud-save place, as its launcher will choose it (dm/mac/launcher.c dm_mac_cloud_place): its preferences, read only, and this Mac's connected NX 18 folder.
    /// nil: not a game app Beam can read
    static func place(app: URL, support: URL = ProfileSetup.macSupport) -> Place? {
        guard let id = Bundle(url: app)?.bundleIdentifier, id != Bundle.main.bundleIdentifier, let d = UserDefaults(suiteName: id) else { return nil }
        return place(d, nx18: ProfileSetup.connectedFolder(support: support))
    }
}

extension NX18CloudSaves.Place {
    /// Where the save lives, in the player's words (the game page)
    var plainWords: String {
        switch self {
        case .off: "Off: this Mac keeps its own save"
        case .own(let f): "In this game's own folder, \((f as NSString).lastPathComponent)"
        case .nx18: "In your NX 18 folder, with your other devices"
        }
    }
}

/// The device facts the settings rules are decided on, as the Mac launcher's macDeviceFacts gives them (dm/mac/Launcher.swift): the fastest screen, controllers,
/// haptics, MetalFX, GPU capture. Beam shows a Mac app's settings on the Mac it will run on, so the facts are this Mac's
@MainActor func beamDeviceFacts() -> DeviceFacts {
    var f = DeviceFacts()
    f.kind = .mac
    f.hz = NSScreen.screens.map(\.maximumFramesPerSecond).max()
    f.haptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    f.controller = !GCController.controllers().isEmpty
    f.tv = false
    if let dev = MTLCreateSystemDefaultDevice() { f.metalFX = MTLFXSpatialScalerDescriptor.supportsMetal4FX(dev) }
    f.gpuCapture = MTLCaptureManager.shared().supportsDestination(.gpuTraceDocument)
    return f
}
