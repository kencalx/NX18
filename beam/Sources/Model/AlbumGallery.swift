// The Album as a console's gallery (beam-design §2a): captures in days, newest first, or by game for Beam Home's all-games Album; their thumbnails, made off the main
// thread and kept in Beam's caches folder; and a recording's trim, saved as a copy beside the original (never over it).
// Nothing here watches a folder: the views read the folders when the Album opens and when Beam comes back to the front
import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension Album {
    /// Ask iCloud for a file it has not brought down yet: only when the player opens it, never for the whole Album
    static func fetch(_ url: URL) { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
}

/// The gallery's groups: days for one game, games for the all-games Album
enum AlbumGrouping {
    struct Day: Equatable, Sendable { let day: Date; let items: [AlbumItem] }
    struct Game: Equatable, Sendable { let id: UUID; let title: String; let items: [AlbumItem] }

    /// Each day with captures, newest day first, newest capture first within a day (the calendar's own days: midnight in the player's time zone)
    static func days(_ items: [AlbumItem], calendar: Calendar = .current) -> [Day] {
        let byDay = Dictionary(grouping: items) { calendar.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { d in Day(day: d, items: byDay[d]!.sorted(by: newestFirst)) }
    }
    /// A day's header: Today, Yesterday, else the weekday and date (with the year when it is not this year's)
    static func title(of day: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) { return "Yesterday" }
        var style = Date.FormatStyle(date: .omitted, time: .omitted).weekday(.wide).month(.wide).day()
        if calendar.component(.year, from: day) != calendar.component(.year, from: now) { style = style.year() }
        style.calendar = calendar; style.timeZone = calendar.timeZone
        return day.formatted(style)
    }
    /// The all-games Album: each game with captures, the one with the newest capture first; games with none left out
    static func games(_ games: [(id: UUID, title: String, items: [AlbumItem])]) -> [Game] {
        games.compactMap { g in g.items.isEmpty ? nil : Game(id: g.id, title: g.title, items: g.items.sorted(by: newestFirst)) }
            .sorted { ($0.items[0].date, $1.title) > ($1.items[0].date, $0.title) }
    }
    static func newestFirst(_ a: AlbumItem, _ b: AlbumItem) -> Bool { a.date != b.date ? a.date > b.date : a.url.lastPathComponent > b.url.lastPathComponent }
}

/// A controller's move through a gallery of groups laid out in rows of `columns`: left and right step through every item (across groups, as a console's Album does),
/// up and down go a row at a time, to the nearest column of the row above or below, across groups too
enum AlbumGridMove {
    enum Direction: Sendable { case left, right, up, down }
    static func move(_ index: Int, _ d: Direction, groups: [Int], columns: Int) -> Int {
        let total = groups.reduce(0, +)
        guard total > 0, columns > 0 else { return 0 }
        let i = min(max(index, 0), total - 1)
        switch d {
        case .left: return max(i - 1, 0)
        case .right: return min(i + 1, total - 1)
        case .up, .down:
            // rows as (first index, count), in order
            var rows: [(start: Int, count: Int)] = [], start = 0
            for n in groups where n > 0 {
                var r = 0
                while r < n { rows.append((start + r, min(columns, n - r))); r += columns }
                start += n
            }
            guard let row = rows.firstIndex(where: { i >= $0.start && i < $0.start + $0.count }) else { return i }
            let col = i - rows[row].start
            let next = d == .up ? row - 1 : row + 1
            guard rows.indices.contains(next) else { return i }
            return rows[next].start + min(col, rows[next].count - 1)
        }
    }
}

/// Thumbnails for the gallery: ImageIO for a picture, AVAssetImageGenerator for a recording's first frame, never on the main thread. Each is kept as a small JPEG in
/// ~/Library/Caches/<Beam's bundle ID>/Album Thumbnails, named by the file's path, size and modification date (and the thumbnail's size), so an edited or replaced
/// capture gets a new one and the old one ages out (prune). A few hundred in memory too, for scrolling back
enum AlbumThumbnails {
    static let pixels = 480
    static var folder: URL { URL.cachesDirectory.appending(path: "\(Bundle.main.bundleIdentifier ?? "org.nx18.beam")/Album Thumbnails", directoryHint: .isDirectory) }
    nonisolated(unsafe) private static let memory: NSCache<NSString, CGImage> = { let c = NSCache<NSString, CGImage>(); c.countLimit = 400; return c }()

    static func key(path: String, size: Int64, modified: Date, pixels: Int) -> String {
        let s = "\(path)\n\(size)\n\(Int64((modified.timeIntervalSince1970 * 1000).rounded()))\n\(pixels)"
        return SHA256.hash(data: Data(s.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
    /// The key for a file as it is now (read fresh: a URL keeps the values it read before), nil when it is not there
    static func key(for url: URL, pixels: Int = pixels) -> String? {
        let fresh = URL(fileURLWithPath: url.path)
        guard let v = try? fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true,
              let size = v.fileSize, let m = v.contentModificationDate else { return nil }
        return key(path: fresh.standardizedFileURL.path, size: Int64(size), modified: m, pixels: pixels)
    }
    static func cacheFile(_ key: String, in folder: URL) -> URL { folder.appending(path: "\(key).jpg") }

    /// The thumbnail: from memory, else the cache folder, else made now and kept. Nil for a file not downloaded, gone, or not a picture or movie
    @concurrent static func thumbnail(for url: URL, kind: AlbumItem.Kind, pixels: Int = pixels, folder: URL = folder) async -> CGImage? {
        guard let key = key(for: url, pixels: pixels) else { return nil }
        if let hit = memory.object(forKey: key as NSString) { return hit }
        let file = cacheFile(key, in: folder)
        if let src = CGImageSourceCreateWithURL(file as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            memory.setObject(img, forKey: key as NSString); return img
        }
        if Task.isCancelled { return nil }   // scrolled past before it was made
        guard let img = await make(url, kind: kind, pixels: pixels) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            _ = CGImageDestinationFinalize(dest)
        }
        memory.setObject(img, forKey: key as NSString)
        return img
    }

    static func make(_ url: URL, kind: AlbumItem.Kind, pixels: Int) async -> CGImage? {
        switch kind {
        case .recording:
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: pixels, height: pixels)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
            return try? await gen.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
        case .screenshot, .document:
            return downsampled(url, pixels: pixels)
        }
    }
    /// A picture at most `pixels` on its long side, turned upright, decoded now (not on first draw)
    static func downsampled(_ url: URL, pixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels,
                                     kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Keeps the cache small: past `limit` files, the oldest go until `keep` are left. Run when the Album opens, off the main thread
    @discardableResult static func prune(folder: URL = folder, limit: Int = 3000, keep: Int = 2000) -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys), files.count > limit else { return 0 }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }.sorted { $0.1 > $1.1 }
        var removed = 0
        for (u, _) in dated.dropFirst(keep) where (try? FileManager.default.removeItem(at: u)) != nil { removed += 1 }
        return removed
    }
}

/// A recording's trim: the part between two times, saved as a new file beside the original ("<name> trimmed.mov", then "trimmed 2", …); the original is never written.
/// Passthrough (no re-encode, fast, no quality lost) when the movie allows it, else re-encoded at the highest quality
enum AlbumTrim {
    enum Failure: Error, LocalizedError {
        case tooShort, cannotExport
        var errorDescription: String? {
            switch self { case .tooShort: "The trimmed part is too short."; case .cannotExport: "This recording could not be trimmed." }
        }
    }
    static let minimumLength = 0.5

    /// The copy's name: the first free one of "<name> trimmed.<ext>", "<name> trimmed 2.<ext>", … in the original's folder. A copy trimmed again stays one "trimmed"
    static func copyURL(for original: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let dir = original.deletingLastPathComponent(), ext = original.pathExtension
        var base = original.deletingPathExtension().lastPathComponent
        if let r = base.range(of: #" trimmed( \d+)?$"#, options: .regularExpression) { base.removeSubrange(r) }
        var n = 1
        while true {
            let name = n == 1 ? "\(base) trimmed" : "\(base) trimmed \(n)"
            let u = dir.appending(path: ext.isEmpty ? name : "\(name).\(ext)")
            if u.standardizedFileURL != original.standardizedFileURL && !exists(u) && !exists(dir.appending(path: ".\(u.lastPathComponent).icloud")) { return u }
            n += 1
        }
    }
    static func fileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() { case "mp4": .mp4; case "m4v": .m4v; default: .mov }
    }

    /// Saves `start`…`end` (seconds) of `original` as a new file and returns it. Written to a temporary folder on the same disk, then moved in under its name, so the
    /// Album never lists a half-written file. The copy is dated a second after the original, so it sits beside it in the Album
    static func export(_ original: URL, start: Double, end: Double) async throws -> URL {
        guard end - start >= minimumLength else { throw Failure.tooShort }
        let asset = AVURLAsset(url: original)
        let type = fileType(for: original)
        let passthrough = await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: type)
        guard let session = AVAssetExportSession(asset: asset, presetName: passthrough ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality)
        else { throw Failure.cannotExport }
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        let fm = FileManager.default
        let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: original.deletingLastPathComponent(), create: true)
        defer { try? fm.removeItem(at: scratch) }
        let temp = scratch.appending(path: "trim.\(original.pathExtension.isEmpty ? "mov" : original.pathExtension)")
        try await session.export(to: temp, as: type)
        let out = copyURL(for: original)
        try fm.moveItem(at: temp, to: out)
        if let d = try? original.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]), let when = d.creationDate ?? d.contentModificationDate {
            try? fm.setAttributes([.creationDate: when + 1, .modificationDate: when + 1], ofItemAtPath: out.path)
        }
        return out
    }
}
