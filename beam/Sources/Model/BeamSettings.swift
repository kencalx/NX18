// Beam's own choices, in its preferences (paths only: the keys file's path is stored, never its contents; secrets go to the Keychain, beam-design §4.5)
import Foundation
import Observation

@MainActor @Observable final class BeamSettings {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        nx18Folder = defaults.url(forKey: "nx18Folder") ?? NX18Checkout.defaultFolder
        keys = defaults.url(forKey: "keys")
        buildSpace = defaults.url(forKey: "buildSpace")
        welcomed = defaults.bool(forKey: "welcomed")
        teamID = defaults.string(forKey: "team")
        signWith = defaults.string(forKey: "signWith")
        updateChecks = defaults.bool(forKey: "updateChecks")
        lastUpdateCheck = defaults.object(forKey: "lastUpdateCheck") as? Date
        whatsNewSeen = defaults.string(forKey: "whatsNewSeen")
        icloudNX18Folder = defaults.url(forKey: "icloudNX18Folder")
    }
    var nx18Folder: URL { didSet { defaults.set(nx18Folder, forKey: "nx18Folder") } }
    var keys: URL? { didSet { defaults.set(keys, forKey: "keys") } }                    // prod.keys dumped from the player's own console, for NSPs
    var buildSpace: URL? { didSet { defaults.set(buildSpace, forKey: "buildSpace") } }  // nil: each game's build folder beside its files
    var welcomed: Bool { didSet { defaults.set(welcomed, forKey: "welcomed") } }
    var teamID: String? { didSet { defaults.set(teamID, forKey: "team") } }
    var signWith: String? { didSet { defaults.set(signWith, forKey: "signWith") } }
    var updateChecks: Bool { didSet { defaults.set(updateChecks, forKey: "updateChecks") } }          // off until the player turns it on (the welcome screen asks)
    var lastUpdateCheck: Date? { didSet { defaults.set(lastUpdateCheck, forKey: "lastUpdateCheck") } }
    var icloudNX18Folder: URL? { didSet { defaults.set(icloudNX18Folder, forKey: "icloudNX18Folder") } }   // the iCloud NX 18 folder the Album reads (nil: as the Mac game apps have it, Album.nx18Folder)
    var whatsNewSeen: String? { didSet { defaults.set(whatsNewSeen, forKey: "whatsNewSeen") } }      // the Beam version whose What's new was shown   // nil: the Apple account in Xcode; "cert:<certificate SHA-1>|<profile UUID>": a certificate   // the Xcode team iPhone installs sign with (kept, never shown)
    /// The chosen team among those in Xcode, else Xcode's first (a paid team before a Personal Team)
    var team: XcodeTeam? { let all = XcodeTeam.inXcode(); return all.first { $0.id == teamID } ?? all.first }
    var checkout: NX18Checkout { NX18Checkout(folder: nx18Folder) }
}
