// Beam Home's Profile chip: which copy of the NX 18 Profile it shows (the higher stamp, as the game apps decide), the name's fallback and the picture, with a made-up home
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import NX_18_Beam

@Suite struct ProfileTests {
    func write(_ u: URL, _ s: String) throws {
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(s.utf8).write(to: u)
    }
    func jpeg(_ u: URL, side: Int) throws {
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 0, green: 0.78, blue: 0.96, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let d = CGImageDestinationCreateWithURL(u as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil); #expect(CGImageDestinationFinalize(d))
    }
    func home() -> URL { FileManager.default.temporaryDirectory.appending(path: "beam-profile-\(UUID().uuidString)") }

    @Test func noneSetShowsPlayer() {
        let h = home(); defer { try? FileManager.default.removeItem(at: h) }
        let p = BeamProfile.load(home: h, nx18: nil)
        #expect(p.name == "Player" && p.picture == nil)
    }

    @Test func higherStampWins() throws {
        let h = home(); defer { try? FileManager.default.removeItem(at: h) }
        let mac = h.appending(path: "Library/Application Support/nxnative/Profile"), nx = h.appending(path: "NX saves")
        try write(mac.appending(path: "name.txt"), "MacName\n"); try write(mac.appending(path: "profile.stamp"), "3 mac\n")
        try write(nx.appending(path: "Profile/name.txt"), "Cody\n"); try write(nx.appending(path: "Profile/profile.stamp"), "4 phone\n")
        try jpeg(nx.appending(path: "Profile/picture.jpg"), side: 256)
        let p = BeamProfile.load(home: h, nx18: nx)
        #expect(p.name == "Cody", "the folder's edit is newer (generation 4 over 3)")
        #expect(p.picture.map { max($0.width, $0.height) } == 96, "the picture is shrunk for the bar")
        try write(mac.appending(path: "profile.stamp"), "5 mac\n")
        #expect(BeamProfile.load(home: h, nx18: nx).name == "MacName", "negative control: a higher Mac stamp wins back")
        #expect(BeamProfile.load(home: h, nx18: nil).name == "MacName", "no NX 18 folder: the Mac's copy")
    }

    @Test func folderNotDownloadedFallsBackToMac() throws {   // only the stamp has arrived from iCloud: its name is not there yet, so the chip keeps the Mac's
        let h = home(); defer { try? FileManager.default.removeItem(at: h) }
        let mac = h.appending(path: "Library/Application Support/nxnative/Profile"), nx = h.appending(path: "NX 18")
        try write(mac.appending(path: "name.txt"), "  \n"); try write(mac.appending(path: "profile.stamp"), "1 mac\n")
        try write(nx.appending(path: "Profile/profile.stamp"), "2 phone\n")
        #expect(BeamProfile.load(home: h, nx18: nx).name == "Player", "a blank name reads as Player")
    }
}
