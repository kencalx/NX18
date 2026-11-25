// Checks before a build starts (beam-design §3.3): room on the disk, and whether the Mac is on battery
import Foundation
import IOKit.ps

enum Preflight {
    /// The game's size: a .nup or .nx file's, or a folder's files (NSPs, XCIs, a dump) added up
    static func gameBytes(_ source: URL) -> Int64 {
        let fm = FileManager.default
        var dir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &dir) else { return 0 }
        if !dir.boolValue { return Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        var total: Int64 = 0
        let e = fm.enumerator(at: source, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) { _, _ in true }
        while let u = e?.nextObject() as? URL {
            if u.lastPathComponent == "build" || u.lastPathComponent.hasSuffix("_build") { e?.skipDescendants(); continue }   // build folders are not the game
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }
    /// What a build needs free where its build folder goes: twice the game plus 10 GB
    static func neededBytes(gameBytes: Int64) -> Int64 { 2 * gameBytes + 10 * 1_000_000_000 }

    /// Free space on the volume a folder is (or will be) on: the first ancestor that exists is asked
    static func freeBytes(at folder: URL) -> Int64? {
        var u = folder
        while !FileManager.default.fileExists(atPath: u.path), u.pathComponents.count > 1 { u = u.deletingLastPathComponent() }
        let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = v?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return v?.volumeAvailableCapacity.map(Int64.init)
    }

    /// True on battery power (a MacBook unplugged)
    static var onBattery: Bool {
        guard let t = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() else { return false }
        return (t as String) == kIOPMBatteryPowerKey
    }
}

/// The script's reasons rewritten as a sentence for the player where Beam knows them; anything else is shown as the script gave it (beam-design §3.3)
enum FriendlyError {
    static func text(_ red: String) -> String {
        let l = red.lowercased()
        if l.contains("metal compiler") && l.contains("tested with") {
            return "This Mac's Xcode is not the one NX 18's shaders were tested with. Install the Xcode version NX 18 names, then build again. (\(red))"
        }
        if l.contains("master key") || (l.contains("keys") && (l.contains("cannot open") || l.contains("too old") || l.contains("missing"))) {
            return "Your keys cannot open this game. Dump the keys again from your own console, updated to the game's firmware, and choose them in Settings. (\(red))"
        }
        if l.contains("no space") || l.contains("not enough space") || l.contains("disk is full") {
            return "The disk ran out of space during the build. Free some space or choose a build space on another disk in Settings. (\(red))"
        }
        if l.contains("missing modules") {
            return "The Python NX 18 uses is missing the build's modules. Run NX 18's setup (scripts/release/nx18-setup.sh) once. (\(red))"
        }
        if l.contains("32-bit arm") {
            return "This game is 32-bit ARM code, which Apple silicon cannot run. NX 18 cannot build it."
        }
        return red
    }
}
