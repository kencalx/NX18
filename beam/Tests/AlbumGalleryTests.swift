// The Album gallery (AlbumGallery.swift) in temporary folders: days and games in order, a controller's moves through the grid, thumbnail cache keys (a changed file gets a
// new one) and the cache's pruning, and a recording's trim (a made-up two-second movie): the copy's name, its length, the original untouched
import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import NX_18_Beam

enum AlbumFixtures {
    static func folder() -> URL { FileManager.default.temporaryDirectory.appending(path: "beam-gallery-\(UUID().uuidString)", directoryHint: .isDirectory) }
    static func item(_ name: String, _ date: Date, _ kind: AlbumItem.Kind = .screenshot) -> AlbumItem {
        AlbumItem(url: URL(fileURLWithPath: "/tmp/album/\(name)"), kind: kind, place: .mac, date: date)
    }
    static func png(_ u: URL, side: Int = 64) throws {
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0.4, blue: 0.3, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let d = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil); _ = CGImageDestinationFinalize(d)
    }
    /// A tiny H.264 movie: `seconds` long at 30 frames a second, 64 × 64
    static func movie(_ u: URL, seconds: Int = 2) async throws {
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let w = try AVAssetWriter(outputURL: u, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let frames = w.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
        try w.start()
        w.startSession(atSourceTime: .zero)
        for f in 0..<(seconds * 30) {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pb)
            CVPixelBufferLockBaseAddress(pb!, []); memset(CVPixelBufferGetBaseAddress(pb!), Int32(f * 4 % 255), CVPixelBufferGetDataSize(pb!)); CVPixelBufferUnlockBaseAddress(pb!, [])
            try await frames.append(CVReadOnlyPixelBuffer(unsafeBuffer: pb!), with: CMTime(value: CMTimeValue(f), timescale: 30))
        }
        frames.finish()
        await w.finishWriting()
        if w.status != .completed { throw w.error ?? CocoaError(.fileWriteUnknown) }
    }
}

@Suite struct AlbumGalleryTests {
    var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; c.locale = Locale(identifier: "en_US"); return c }

    @Test func daysNewestFirst() {
        let d = { (s: String) in ISO8601DateFormatter().date(from: s)! }
        let items = [AlbumFixtures.item("a.png", d("2026-11-25T08:00:00Z")), AlbumFixtures.item("b.png", d("2026-11-26T23:59:00Z")),
                     AlbumFixtures.item("c.mov", d("2026-11-25T21:00:00Z"), .recording), AlbumFixtures.item("d.png", d("2026-11-26T00:00:00Z"))]
        let days = AlbumGrouping.days(items, calendar: utc)
        #expect(days.map { $0.items.map(\.url.lastPathComponent) } == [["b.png", "d.png"], ["c.mov", "a.png"]])
        let now = d("2026-11-26T12:00:00Z")
        #expect(AlbumGrouping.title(of: days[0].day, now: now, calendar: utc) == "Today")
        #expect(AlbumGrouping.title(of: days[1].day, now: now, calendar: utc) == "Yesterday")
        #expect(AlbumGrouping.title(of: d("2026-11-20T00:00:00Z"), now: now, calendar: utc) == "Friday, November 20")
        #expect(AlbumGrouping.title(of: d("2025-11-20T00:00:00Z"), now: now, calendar: utc).contains("2025"), "another year's date says the year")
    }

    @Test func gamesByNewestCapture() {
        let t = Date(timeIntervalSince1970: 1_800_000_000), a = UUID(), b = UUID(), c = UUID()
        let g = AlbumGrouping.games([(a, "Older", [AlbumFixtures.item("1.png", t), AlbumFixtures.item("2.png", t + 10)]),
                                     (b, "None", []),
                                     (c, "Newer", [AlbumFixtures.item("3.png", t + 20)])])
        #expect(g.map(\.title) == ["Newer", "Older"], "the game with the newest capture first; a game with none left out")
        #expect(g[1].items.map(\.url.lastPathComponent) == ["2.png", "1.png"])
    }

    @Test func controllerMoves() {
        // two groups of 3 and 5 in rows of 2:  [0 1] [2] | [3 4] [5 6] [7]
        let m = { (i: Int, d: AlbumGridMove.Direction) in AlbumGridMove.move(i, d, groups: [3, 5], columns: 2) }
        #expect(m(2, .right) == 3 && m(3, .left) == 2, "left and right run on across groups")
        #expect(m(1, .down) == 2, "down to a shorter row: its last tile")
        #expect(m(2, .down) == 3 && m(3, .up) == 2, "down and up cross into the next group's row")
        #expect(m(4, .up) == 2, "up from the second column to a one-tile row")
        #expect(m(7, .down) == 7 && m(0, .up) == 0 && m(0, .left) == 0 && m(7, .right) == 7, "edges stay put")
        #expect(AlbumGridMove.move(5, .down, groups: [], columns: 4) == 0)
    }

    @Test func thumbnailKeysFollowTheFile() async throws {
        let dir = AlbumFixtures.folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let shot = dir.appending(path: "Captures/2026-11-25 21.04.17.png"), cache = dir.appending(path: "cache")
        try AlbumFixtures.png(shot)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: t], ofItemAtPath: shot.path)
        let k1 = try #require(AlbumThumbnails.key(for: shot))
        #expect(AlbumThumbnails.key(for: shot) == k1, "the same file, the same key")
        #expect(AlbumThumbnails.key(for: shot, pixels: 240) != k1, "another size, another key")
        #expect(AlbumThumbnails.key(for: dir.appending(path: "gone.png")) == nil)

        let img = await AlbumThumbnails.thumbnail(for: shot, kind: .screenshot, pixels: 32, folder: cache)
        #expect(img.map { max($0.width, $0.height) } == 32)
        let k32 = try #require(AlbumThumbnails.key(for: shot, pixels: 32))
        #expect(FileManager.default.fileExists(atPath: AlbumThumbnails.cacheFile(k32, in: cache).path), "kept in the cache folder")

        try FileManager.default.setAttributes([.modificationDate: t + 60], ofItemAtPath: shot.path)
        #expect(AlbumThumbnails.key(for: shot) != k1, "a newer modification date: a new key")
        try AlbumFixtures.png(shot, side: 80)
        try FileManager.default.setAttributes([.modificationDate: t], ofItemAtPath: shot.path)
        #expect(AlbumThumbnails.key(for: shot) != k1, "another size on disk, same date: a new key")
        _ = await AlbumThumbnails.thumbnail(for: shot, kind: .screenshot, pixels: 32, folder: cache)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).count == 2, "the replaced file got its own thumbnail")
    }

    @Test func pruneKeepsTheNewest() throws {
        let dir = AlbumFixtures.folder(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<6 {
            let u = dir.appending(path: "\(i).jpg"); try Data([0]).write(to: u)
            try FileManager.default.setAttributes([.modificationDate: t + Double(i)], ofItemAtPath: u.path)
        }
        #expect(AlbumThumbnails.prune(folder: dir, limit: 10, keep: 3) == 0, "under the limit: nothing goes")
        #expect(AlbumThumbnails.prune(folder: dir, limit: 5, keep: 3) == 3)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["3.jpg", "4.jpg", "5.jpg"])
    }

    @Test func trimCopyNames() {
        let dir = URL(fileURLWithPath: "/tmp/album/Captures")
        let rec = dir.appending(path: "2026-11-26 09.00.00.mov")
        #expect(AlbumTrim.copyURL(for: rec, exists: { _ in false }).lastPathComponent == "2026-11-26 09.00.00 trimmed.mov")
        let taken: Set<String> = ["2026-11-26 09.00.00 trimmed.mov", ".2026-11-26 09.00.00 trimmed 2.mov.icloud"]
        #expect(AlbumTrim.copyURL(for: rec, exists: { taken.contains($0.lastPathComponent) }).lastPathComponent == "2026-11-26 09.00.00 trimmed 3.mov",
                "a copy already there, or still in iCloud, is never written over")
        #expect(AlbumTrim.copyURL(for: dir.appending(path: "2026-11-26 09.00.00 trimmed.mov"), exists: { taken.contains($0.lastPathComponent) }).lastPathComponent
                == "2026-11-26 09.00.00 trimmed 3.mov", "a trimmed copy trimmed again: never its own name, never \"trimmed trimmed\"")
        #expect(AlbumTrim.copyURL(for: dir.appending(path: "clip.mp4"), exists: { _ in false }).lastPathComponent == "clip trimmed.mp4")
        #expect(AlbumTrim.fileType(for: dir.appending(path: "clip.MP4")) == .mp4 && AlbumTrim.fileType(for: rec) == .mov)
    }

    @Test func trimExportsACopy() async throws {
        let dir = AlbumFixtures.folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let rec = dir.appending(path: "Captures/2026-11-26 09.00.00.mov")
        try await AlbumFixtures.movie(rec, seconds: 2)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.creationDate: t, .modificationDate: t], ofItemAtPath: rec.path)
        let before = try Data(contentsOf: rec)

        await #expect(throws: AlbumTrim.Failure.self) { try await AlbumTrim.export(rec, start: 1, end: 1.2) }
        let out = try await AlbumTrim.export(rec, start: 0.5, end: 1.5)
        #expect(out.lastPathComponent == "2026-11-26 09.00.00 trimmed.mov" && out.deletingLastPathComponent() == rec.deletingLastPathComponent())
        #expect(try Data(contentsOf: rec) == before, "the original is untouched")
        let seconds = try await AVURLAsset(url: out).load(.duration).seconds
        #expect(seconds > 0.4 && seconds < 1.6, "about a second kept (passthrough cuts at frames), got \(seconds)")
        let dated = try out.resourceValues(forKeys: [.creationDateKey]).creationDate
        #expect(dated == t + 1, "dated beside the original")
        let again = try await AlbumTrim.export(rec, start: 0, end: 1)
        #expect(again.lastPathComponent == "2026-11-26 09.00.00 trimmed 2.mov", "a second trim: a second copy")
        let listed = Album.read(rec.deletingLastPathComponent(), place: .mac, captures: true, download: false)
        #expect(listed.count == 3 && listed.allSatisfy { $0.kind == .recording }, "nothing half-written left in the folder")
    }
}
