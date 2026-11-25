// What NX 18's shared UI files expect from the app that compiles them. The Mac launcher's Launcher.swift has the real ones; Beam stands in for them here.
import CoreHaptics
import AppKit
import Foundation
import GameController
import Metal
import MetalFX

@MainActor enum MacCloud {   // LauncherPanel's Cloud saves page names the chosen folder: the game's whose settings Beam shows (GameSettingsView sets defaults)
    static var defaults: UserDefaults = .standard
    static var folderName: String? {
        let f = defaults.string(forKey: "cloudSaves.folder") ?? ""
        return f.isEmpty ? nil : (f as NSString).lastPathComponent
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
