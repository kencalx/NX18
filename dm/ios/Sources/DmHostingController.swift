import SwiftUI
import UIKit

// Full-screen SwiftUI presentations must preserve the game's four-orientation policy.
final class DmHostingController<Content: View>: UIHostingController<Content> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    // The look the NX 18 card's Appearance choice asks for (NX18Look.swift): Match device leaves the style unspecified, Light and Dark hold one. A change on the card applies at
    // once, to this screen, its sheets and the system pieces presented from it
    nonisolated(unsafe) private var lookObserver: NSObjectProtocol?   // set once on the main thread; removed in deinit
    func followAppearance() {
        overrideUserInterfaceStyle = NX18Appearance.current.style
        guard lookObserver == nil else { return }
        lookObserver = NotificationCenter.default.addObserver(forName: NX18Appearance.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.overrideUserInterfaceStyle = NX18Appearance.current.style }
        }
    }
    deinit { if let o = lookObserver { NotificationCenter.default.removeObserver(o) } }
}
