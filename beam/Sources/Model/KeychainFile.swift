// Beam's keychain file, made and unlocked without its password on a command line (CertificateSigning.swift, BeamKeychain): another process of the same user can
// read a command line (ps), so the password goes to the Security framework in Beam's own process, and to `security set-key-partition-list`, which has no API,
// on its standard input in a session of its own.
// The calls are SecKeychain's file-keychain API: deprecated, and the only one for a keychain file of its own (the data-protection keychain has no files); they
// are called through LegacyKeychainCalls, which keeps their deprecation warnings out of the build
import Darwin
import Foundation
import Security

enum KeychainFile {
    enum Failure: LocalizedError, Equatable {
        case status(String, OSStatus)
        var errorDescription: String? {
            switch self { case .status(let what, let st): "\(what) (\(SecCopyErrorMessageString(st, nil) as String? ?? "error \(st)"))." }
        }
    }

    /// Makes the keychain file `path` with `password`: no lock after a timeout or at sleep, and the user's keychain search list left as it was
    static func create(_ path: URL, password: String, calls: any LegacyKeychain.Type = LegacyKeychainCalls.self) throws {
        let before = calls.searchList()
        let st = calls.create(path.path, password: Array(password.utf8))
        // never Beam's keychain in the list, also when making it failed part way (the file made, its settings not)
        if let before, let now = calls.searchList(), now.count != before.count { _ = calls.setSearchList(before) }
        guard st == errSecSuccess else { throw Failure.status("Could not make Beam's keychain", st) }
    }

    /// Unlocks the keychain file `path` with `password`
    static func unlock(_ path: URL, password: String) throws {
        let st = (LegacyKeychainCalls.self as any LegacyKeychain.Type).unlock(path.path, password: Array(password.utf8))
        guard st == errSecSuccess else { throw Failure.status("Could not unlock Beam's keychain", st) }
    }

    /// Lets codesign use the signing keys in the keychain file `path` without asking (their partition list: apple-tool, apple, codesign). `security` reads the
    /// password from its standard input, which it does when it has no terminal: it runs in a session of its own, with no controlling terminal even when Beam has one
    static func allowCodesign(_ path: URL, password: String) async throws {
        let r = try await Tool.run("/usr/bin/security", ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", path.path], input: Data((password + "\n").utf8))
        guard r.code == 0 else { throw Failure.status("Could not let codesign use the certificate's key", OSStatus(r.code)) }
    }
}

/// The deprecated calls, behind a protocol: a call through the protocol is not a use of a deprecated declaration, so the build stays free of their warnings
protocol LegacyKeychain {
    static func create(_ path: String, password: [UInt8]) -> OSStatus
    static func unlock(_ path: String, password: [UInt8]) -> OSStatus
    static func searchList() -> [SecKeychain]?
    static func setSearchList(_ list: [SecKeychain]) -> OSStatus
}

enum LegacyKeychainCalls: LegacyKeychain {
    @available(macOS, deprecated: 10.10)
    static func create(_ path: String, password: [UInt8]) -> OSStatus {
        var kc: SecKeychain?
        let st = SecKeychainCreate(path, UInt32(password.count), password, false, nil, &kc)
        guard st == errSecSuccess, let kc else { return st }
        var s = SecKeychainSettings(version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1), lockOnSleep: false, useLockInterval: false, lockInterval: UInt32(INT32_MAX))
        _ = SecKeychainSetSettings(kc, &s)   // what `security set-keychain-settings` with no options sets: never locked by a timeout or sleep. As before, not a failure
        return errSecSuccess                 // of the keychain's making: the file is there, and a throw here would leave it without a retry (ready() only unlocks it)
    }
    @available(macOS, deprecated: 10.10)
    static func unlock(_ path: String, password: [UInt8]) -> OSStatus {
        var kc: SecKeychain?
        let st = SecKeychainOpen(path, &kc)
        guard st == errSecSuccess, let kc else { return st }
        return SecKeychainUnlock(kc, UInt32(password.count), password, true)
    }
    @available(macOS, deprecated: 10.10)
    static func searchList() -> [SecKeychain]? {
        var list: CFArray?
        guard SecKeychainCopyDomainSearchList(.user, &list) == errSecSuccess else { return nil }
        return list as? [SecKeychain]
    }
    @available(macOS, deprecated: 10.10)
    static func setSearchList(_ list: [SecKeychain]) -> OSStatus { SecKeychainSetDomainSearchList(.user, list as CFArray) }
}
