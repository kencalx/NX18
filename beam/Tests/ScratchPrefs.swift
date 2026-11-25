// A test's own preferences domain, gone after the test: the domain removed, cfprefsd told (so it does not write the file back later), the file deleted
import CoreFoundation
import Foundation

enum ScratchPrefs {
    static func clean(_ suite: String) {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        CFPreferencesAppSynchronize(suite as CFString)
        try? FileManager.default.removeItem(at: URL.libraryDirectory.appending(path: "Preferences/\(suite).plist"))
    }
}
