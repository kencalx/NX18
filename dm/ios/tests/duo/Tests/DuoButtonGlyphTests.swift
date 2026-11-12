import SwiftUI
import UIKit
import XCTest
@testable import DuoHarness

// The controller hints' button glyphs (NXButtonGlyph.swift, Zacksly's pack): which glyph a pad shows for a Switch button, that each glyph is drawn as a disc with its label cut
// out and in the colour it is given; and the launchers' flowing rails (LauncherRow.swift NX18RailsFlowView): a Core Animation slide while in a window, none under Reduce Motion
// or out of a window
final class DuoButtonGlyphTests: XCTestCase {
    func testAHintShowsTheButtonThePlayerPresses() {
        // A Nintendo pad: its labels
        XCTAssertEqual(NXPadGlyphs.resolve(.a, labelled: true, symbol: "a.circle", fallback: .b), .button(.a))
        XCTAssertEqual(NXPadGlyphs.resolve(.plus, labelled: true, symbol: "plus.circle", fallback: .plus), .button(.plus))
        // An Xbox pad by position: the Switch's A is its right button, B, drawn as the pack's B; the Switch's Y its left one, X
        XCTAssertEqual(NXPadGlyphs.resolve(.a, labelled: false, symbol: "b.circle", fallback: .b), .button(.b))
        XCTAssertEqual(NXPadGlyphs.resolve(.y, labelled: false, symbol: "x.circle.fill", fallback: .x), .button(.x))
        // A PlayStation pad: its own shapes, as SF Symbols; its cross is no X
        XCTAssertEqual(NXPadGlyphs.resolve(.a, labelled: false, symbol: "circle.circle", fallback: .b), .symbol("circle.circle"))
        XCTAssertEqual(NXPadGlyphs.resolve(.b, labelled: false, symbol: "xmark.circle", fallback: .a), .symbol("xmark.circle"))
        XCTAssertEqual(NXPadGlyphs.resolve(.plus, labelled: false, symbol: "line.3.horizontal.circle", fallback: .plus), .symbol("line.3.horizontal.circle"))
        // A pad that names no symbol: the letter of its button in that place
        XCTAssertEqual(NXPadGlyphs.resolve(.a, labelled: false, symbol: nil, fallback: .b), .button(.b))
        // No controller: the Switch's own glyphs and names
        XCTAssertEqual(NXPadGlyphs().glyph(.y), .button(.y))
        XCTAssertEqual(NXPadGlyphs().name(.plus), "plus")
        XCTAssertEqual(NXPadGlyphs().name(NXShoulder.l), "L")
        XCTAssertEqual(NXPadGlyphs().name(NXShoulder.r), "R")
        XCTAssertNil(NXPadGlyphs.letter(ofSymbol: "xmark.circle"))
        XCTAssertEqual(NXPadGlyphs.letter(ofSymbol: "y.circle"), .y)
    }

    // The glyph at 64 x 64 in coral on charcoal: the disc's edge and the middle of its label, and outside it
    @MainActor
    func testEachGlyphIsADiscWithItsLabelCutOutInTheColourGiven() throws {
        for b in NXButton.allCases {
            let view = NXButtonGlyphShape(button: b).fill(NX18Palette.coral).frame(width: 64, height: 64).background(NX18Palette.charcoal)
            let r = ImageRenderer(content: view); r.scale = 1
            let image = try XCTUnwrap(r.cgImage, b.rawValue)
            let px = try pixels(image)
            func at(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * 64 + x) * 4; return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2])) }
            let coral = (0xFF, 0x6B, 0x5A), charcoal = (0x2A, 0x2A, 0x2D)
            func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool { abs(a.0 - b.0) < 24 && abs(a.1 - b.1) < 24 && abs(a.2 - b.2) < 24 }
            XCTAssertTrue(near(at(32, 4), coral), "\(b): the disc's top in the colour given")
            XCTAssertTrue(near(at(6, 32), coral), "\(b): the disc's left")
            XCTAssertTrue(near(at(1, 1), charcoal), "\(b): outside the disc")
            var cut = 0
            for y in 16..<48 { for x in 16..<48 where near(at(x, y), charcoal) { cut += 1 } }
            XCTAssertGreaterThan(cut, 60, "\(b): its label is cut out of the disc")
            XCTAssertLessThan(cut, 32 * 32 / 2, "\(b): most of the middle is still the disc")
        }
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        return px
    }

    @MainActor
    func testRailsFlowOnlyInAWindowAndNotUnderReduceMotion() throws {
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow))
        let rails = NX18RailsFlowView(axis: .vertical)
        rails.frame = CGRect(x: 0, y: 0, width: 2.5, height: 300)
        rails.layoutIfNeeded()
        XCTAssertFalse(rails.isFlowing, "Out of a window: still")
        window.addSubview(rails)
        rails.layoutIfNeeded()
        XCTAssertTrue(rails.isFlowing, "In a window: the slide runs")
        let slide = try XCTUnwrap(rails.layer.sublayers?.first?.animation(forKey: NX18RailsFlowView.key))
        XCTAssertLessThanOrEqual(slide.preferredFrameRateRange.maximum, 30, "A slow drift: no ProMotion rate for it")
        rails.moving = false
        XCTAssertFalse(rails.isFlowing, "Reduce Motion: still")
        rails.moving = true
        XCTAssertTrue(rails.isFlowing)
        rails.removeFromSuperview()
        XCTAssertFalse(rails.isFlowing, "Off screen: stopped")
        XCTAssertGreaterThanOrEqual(NX18RailsFlowView.period, 6, "A slow cycle of several seconds")
    }
}
