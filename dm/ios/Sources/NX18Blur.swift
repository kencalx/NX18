// The Gate's wash blur (LauncherArt.wash) on the CPU: a few box-blur passes each way over a small RGBA bitmap, which together come out about a Gaussian. It takes the place of a
// Core Image blur, whose context (and so the first Metal device) would come before the game's own (Launcher.swift metalDeviceMade, #840). Core Graphics and Foundation only,
// so the Mac checks it against Core Image (dm/ios/tests/blur_check.swift). Pixels beyond the edge are the edge's own (as Core Image's clampedToExtent), and the passes run in linear
// light, as Core Image's working space does, so the colours mix as they did before
import CoreGraphics
import Foundation

enum NX18Blur {
    // Three passes of radius 2, 2 and 3 (a variance of 2 + 2 + 4 = 8): of the three-pass sets, the nearest to the Core Image sigma 3 blur the wash had (blur_check.swift:
    // under 1 of 255 apart on average, a few levels at most on pictures)
    static let washRadii = [2, 2, 3]

    // sRGB to linear light and back, as tables over the 256 byte values and a fine table back
    private static let toLinear: [Float] = (0..<256).map { i in
        let c = Float(i) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }
    private static let fromLinearSteps = 4096
    private static let fromLinear: [UInt8] = (0...fromLinearSteps).map { i in
        let l = Float(i) / Float(fromLinearSteps)
        let c = l <= 0.0031308 ? l * 12.92 : 1.055 * powf(l, 1 / 2.4) - 0.055
        return UInt8(Swift.min(255, Swift.max(0, (c * 255).rounded())))
    }

    // Blurs a bitmap context of 8-bit RGBA (premultiplied, alpha last) in place. false when the context is not that shape
    @discardableResult
    static func blur(_ ctx: CGContext, radii: [Int] = washRadii) -> Bool {
        let w = ctx.width, h = ctx.height
        guard w > 0, h > 0, ctx.bitsPerComponent == 8, ctx.bitsPerPixel == 32, let data = ctx.data else { return false }
        let row = ctx.bytesPerRow, px = data.bindMemory(to: UInt8.self, capacity: row * h)
        // the colours in linear light; alpha as it is (premultiplied colour over an alpha of 1 is the colour, the art's usual case)
        var a = [Float](repeating: 0, count: w * h * 4), b = a
        for y in 0..<h {
            for x in 0..<w {
                let s = y * row + x * 4, d = (y * w + x) * 4
                let al = Float(px[s + 3]) / 255
                for c in 0..<3 { a[d + c] = al > 0 ? toLinear[Int(Swift.min(255, (Float(px[s + c]) / al).rounded()))] * al : 0 }
                a[d + 3] = al
            }
        }
        func pass(_ src: [Float], _ dst: inout [Float], r: Int, horizontal: Bool) {
            let lines = horizontal ? h : w, n = horizontal ? w : h, scale = 1 / Float(2 * r + 1)
            for line in 0..<lines {
                @inline(__always) func index(_ k: Int) -> Int { let k = Swift.min(Swift.max(k, 0), n - 1); return (horizontal ? line * w + k : k * w + line) * 4 }
                for c in 0..<4 {
                    var sum: Float = 0
                    for k in -r...r { sum += src[index(k) + c] }
                    for k in 0..<n {
                        dst[index(k) + c] = sum * scale
                        sum += src[index(k + r + 1) + c] - src[index(k - r) + c]
                    }
                }
            }
        }
        for r in radii where r > 0 { pass(a, &b, r: r, horizontal: true); pass(b, &a, r: r, horizontal: false) }
        for y in 0..<h {
            for x in 0..<w {
                let s = y * row + x * 4, d = (y * w + x) * 4
                let al = Swift.min(1, Swift.max(0, a[d + 3]))
                for c in 0..<3 {
                    let l = al > 0 ? Swift.min(1, Swift.max(0, a[d + c] / al)) : 0
                    px[s + c] = UInt8((Float(fromLinear[Int((l * Float(fromLinearSteps)).rounded())]) * al).rounded())
                }
                px[s + 3] = UInt8((al * 255).rounded())
            }
        }
        return true
    }
}
