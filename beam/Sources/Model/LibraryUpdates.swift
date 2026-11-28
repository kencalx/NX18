// The library's side of Beam's updates (Updates.swift): the daily check, and installing a release when the player says so.
import AppKit
import Foundation

enum UpdateStep: Equatable {
    case working(String)     // "Downloading…", "Checking…"
    case failed(String)      // in plain words; the banner keeps the release's link
    var isWorking: Bool { if case .working = self { true } else { false } }
}

extension Library {
    /// The daily check, when the player turned it on and a day has passed since the last one
    func checkForUpdateIfDue(now: Date = .now) async {
        guard settings.updateChecks else { return }
        if let last = settings.lastUpdateCheck, now.timeIntervalSince(last) < BeamUpdate.day { return }
        settings.lastUpdateCheck = now
        updateAvailable = try? await BeamUpdate.check(current: BeamUpdate.currentVersion)
    }

    /// Beam can put the update in itself: it is signed with the Developer ID (so it can check the new one), it sits where it can write, and the release has its DMG
    var canInstallUpdate: Bool {
        guard let r = updateAvailable, r.dmg != nil else { return false }
        return BeamUpdate.requirement(team: BeamUpdate.ownTeam()) != nil && BeamUpdate.installTarget() != nil
    }
    /// A build or install would stop if Beam quit now
    var busyForUpdate: Bool { jobs.values.contains { $0.isActive } }

    /// Downloads, checks and stages the release, then quits; the swap puts the new Beam in place and opens it
    func installUpdate() {
        guard let r = updateAvailable, !busyForUpdate, let target = BeamUpdate.installTarget(),
              let req = BeamUpdate.requirement(team: BeamUpdate.ownTeam()) else { return }
        if updateStep?.isWorking == true { return }
        updateStep = .working("Downloading…")
        let folder = URL.cachesDirectory.appending(path: "NX 18 Beam/Update", directoryHint: .isDirectory)
        Task {
            do {
                let dmg = try await BeamUpdate.download(r, into: folder)
                updateStep = .working("Checking…")
                let staged = try await Task.detached { try BeamUpdate.stage(dmg: dmg, version: r.versionString, beside: target, requirement: req) }.value
                try? FileManager.default.removeItem(at: folder)
                guard !busyForUpdate else { try? FileManager.default.removeItem(at: staged); updateStep = nil; return }   // a build started meanwhile: try again later
                try BeamUpdate.startSwap(staged: staged, target: target)
                NSApp.terminate(nil)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                updateStep = .failed((error as? BeamUpdate.Failure)?.description ?? "The update did not install.")
            }
        }
    }
}
