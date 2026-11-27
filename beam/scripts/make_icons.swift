// Renders Beam's app icon set and welcome title from the NX 18 logo script's SVGs (docs/images/nx18/make_logo.py writes them):
//   python3 docs/images/nx18/make_logo.py && swift beam/scripts/make_icons.swift
// AppIcon: beam-icon-square.svg (full bleed; macOS rounds it) at 16 to 1024 px. BeamTitle: beam-title-dark.svg / -light.svg, copied as vector images.
import AppKit

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let logos = repo.appending(path: "docs/images/nx18")
let assets = repo.appending(path: "beam/Resources/Assets.xcassets")

func png(_ svg: URL, _ px: Int, _ out: URL) throws {
    guard let img = NSImage(contentsOf: svg) else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: svg.path]) }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px)); NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: out)
}
for px in [16, 32, 64, 128, 256, 512, 1024] {
    try png(logos.appending(path: "beam-icon-square.svg"), px, assets.appending(path: "AppIcon.appiconset/icon_\(px).png"))
}
let title = assets.appending(path: "BeamTitle.imageset")
try FileManager.default.createDirectory(at: title, withIntermediateDirectories: true)
for v in ["light", "dark"] {
    let dst = title.appending(path: "beam-title-\(v).svg")
    try? FileManager.default.removeItem(at: dst)
    try FileManager.default.copyItem(at: logos.appending(path: "beam-title-\(v).svg"), to: dst)
}
let contents = """
{
  "images" : [
    { "filename" : "beam-title-light.svg", "idiom" : "universal" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "beam-title-dark.svg", "idiom" : "universal" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "preserves-vector-representation" : true }
}

"""
try contents.write(to: title.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
print("AppIcon and BeamTitle written")
