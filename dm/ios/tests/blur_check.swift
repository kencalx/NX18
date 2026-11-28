// The Gate's wash blur (dm/ios/Sources/NX18Blur.swift) against the Core Image blur it replaced (sigma 3 over the clamped 48 x 27 field, LauncherArt.wash before): the same
// pictures through both, compared byte by byte. test_gate_blur.py compiles it with NX18Blur.swift and runs it; a picture's path on the command line is compared too
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

@main struct BlurCheck {
    nonisolated(unsafe) static var failed = 0
    static func expect(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL: \(what)") } }
    static let w = 48, h = 27
    static func context() -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
    static func field(_ draw: (CGContext) -> Void) -> CGImage { let c = context(); c.interpolationQuality = .high; draw(c); return c.makeImage()! }
    static func bytes(_ img: CGImage) -> [UInt8] {
        let c = context(); c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = c.data!.bindMemory(to: UInt8.self, capacity: c.bytesPerRow * h)
        return (0..<h).flatMap { y in (0..<w * 4).map { p[y * c.bytesPerRow + $0] } }
    }
    static func coreImage(_ small: CGImage) -> CGImage {   // the old wash, as it was
        let ci = CIImage(cgImage: small).clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(ci, from: ci.extent)!
    }
    static func cpu(_ small: CGImage) -> CGImage { let c = context(); c.draw(small, in: CGRect(x: 0, y: 0, width: w, height: h)); expect(NX18Blur.blur(c), "blurs an RGBA8 bitmap"); return c.makeImage()! }
    static func pixel(_ c: CGContext, _ x: Int, _ y: Int, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) { c.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1)); c.fill(CGRect(x: x, y: y, width: 1, height: 1)) }

    static func main() {
        var seed: UInt64 = 0x4e58_3138
        func next() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 40) / CGFloat(1 << 24) }
        var pictures: [(name: String, image: CGImage, maxAllowed: Int, meanAllowed: Double, opaque: Bool)] = [
            ("gradient", field { c in for y in 0..<h { for x in 0..<w { pixel(c, x, y, CGFloat(x) / 47, CGFloat(y) / 26, 1 - CGFloat(x + y) / 73) } } }, 6, 0.8, true),
            ("bars", field { c in
                let k: [(CGFloat, CGFloat, CGFloat)] = [(0.9, 0.1, 0.1), (0.1, 0.8, 0.2), (0.1, 0.2, 0.9), (1, 1, 0.1), (0.05, 0.05, 0.05), (1, 1, 1)]
                for (i, v) in k.enumerated() { c.setFillColor(CGColor(srgbRed: v.0, green: v.1, blue: v.2, alpha: 1)); c.fill(CGRect(x: i * 8, y: 0, width: 8, height: h)) }
            }, 16, 3, true),
            ("checker", field { c in for y in 0..<h { for x in 0..<w { pixel(c, x, y, (x / 4 + y / 4) % 2 == 0 ? 1 : 0, CGFloat(x) / 47, CGFloat(y) / 26) } } }, 16, 1, true),
            ("noise", field { c in for y in 0..<h { for x in 0..<w { pixel(c, x, y, next(), next(), next()) } } }, 24, 1.5, true),
            ("teal into coral", field { c in   // the wash without art
                let colours = [CGColor(srgbRed: 0.0, green: 0.78, blue: 0.80, alpha: 1), CGColor(srgbRed: 1.0, green: 0.42, blue: 0.36, alpha: 1)] as CFArray
                let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours, locations: [0, 1])!
                c.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }, 3, 0.5, true),
        ]
        for f in CommandLine.arguments.dropFirst() {
            guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: f) as CFURL, nil), let i = CGImageSourceCreateImageAtIndex(s, 0, nil) else { expect(false, "cannot read \(f)"); continue }
            pictures.append((URL(fileURLWithPath: f).lastPathComponent, field { $0.draw(i, in: CGRect(x: 0, y: 0, width: w, height: h)) }, 20, 1.5, false))   // an icon may have clear corners
        }
        var total = 0.0, count = 0, worst = 0
        for p in pictures {
            let a = bytes(coreImage(p.image)), b = bytes(cpu(p.image)), o = bytes(p.image)
            var m = 0, t = 0.0, n = 0, moved = 0
            for i in 0..<a.count where i % 4 != 3 { let d = abs(Int(a[i]) - Int(b[i])); m = Swift.max(m, d); t += Double(d); n += 1; moved = Swift.max(moved, abs(Int(o[i]) - Int(b[i]))) }
            let alpha = stride(from: 3, to: b.count, by: 4).allSatisfy { b[$0] == 255 }
            print(String(format: "%@: max %d, mean %.3f of 255 (largest change from the unblurred field %d)", p.name, m, t / Double(n), moved))
            expect(m <= p.maxAllowed, "\(p.name): \(m) levels apart at most, allowed \(p.maxAllowed)")
            expect(t / Double(n) <= p.meanAllowed, "\(p.name): \(t / Double(n)) apart on average, allowed \(p.meanAllowed)")
            expect(alpha || !p.opaque, "\(p.name): stays opaque")
            total += t; count += n; worst = Swift.max(worst, m)
        }
        print(String(format: "all: max %d, mean %.3f of 255", worst, total / Double(count)))
        // not an RGBA8 bitmap: left alone
        let grey = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        expect(!NX18Blur.blur(grey), "a grey bitmap is not blurred")
        print("gate blur: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
