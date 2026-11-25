// The Mac's Gate window (dm/mac/Launcher.swift), run by test_launcher_storage.py: lay out the real window content (the banner and the Gate panel, LauncherPanel.swift) at the
// window's minimum and ideal sizes, in both looks, without creating or showing a window; and the window-fit helper's edges.
import AppKit
import SwiftUI

@MainActor func checkLauncherLayout(_ model: LauncherModel, defaults: UserDefaults) -> Int {
    NSApplication.shared.setActivationPolicy(.prohibited)
    var failed = 0
    func expect(_ c: Bool, _ what: String) { print((c ? "PASS " : "FAIL ") + what); if !c { failed += 1 } }
    for (size, look) in [(NSSize(width: 520, height: 640), "NSAppearanceNameDarkAqua"), (NSSize(width: 600, height: 760), "NSAppearanceNameAqua"), (NSSize(width: 900, height: 900), "NSAppearanceNameDarkAqua")] {
        let view = NSHostingView(rootView: LauncherView(m: model, done: { _ in }, fit: { _ in }).defaultAppStorage(defaults))
        view.appearance = NSAppearance(named: NSAppearance.Name(look))
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        view.layoutSubtreeIfNeeded()
        let fit = view.fittingSize
        expect(fit.width <= max(size.width, 600) + 0.5 && fit.height <= max(size.height, 760) + 0.5, "the Gate asks no more than its ideal 600 x 760 (\(Int(size.width)) x \(Int(size.height)) pt, \(look)): \(Int(fit.width)) x \(Int(fit.height))")
        expect(view.appearance?.name.rawValue == look, "the window's look applies (\(look))")
    }
    let visible = NSRect(x: -1920, y: 40, width: 1920, height: 900)
    let initial = NSRect(x: -1500, y: 540, width: 560, height: 400)
    let expanded = LauncherWindowLayout.fitted(initial, extraHeight: 300, visible: visible)
    let capped = LauncherWindowLayout.fitted(initial, extraHeight: 1200, visible: visible)
    let collapsed = LauncherWindowLayout.fitted(expanded, extraHeight: -300, visible: visible)
    expect(expanded.maxY == initial.maxY && expanded.height == 700, "expansion preserves the top edge")
    expect(capped == NSRect(x: -1500, y: 40, width: 560, height: 900), "tall content stops at the visible screen frame")
    expect(collapsed == initial, "collapse restores the content height and top edge")
    return failed
}
