// Copies Beam's welcome title from the NX 18 logo script's SVGs (docs/images/nx18/make_logo.py writes them):
//   python3 docs/images/nx18/make_logo.py && swift beam/scripts/make_icons.swift
// BeamTitle: beam-title-dark.svg / -light.svg, copied as vector images. The app icon is beam/Resources/AppIcon.icon (Icon Composer's layered
// format), which make_logo.py writes itself: nothing to render here.
import Foundation

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let logos = repo.appending(path: "docs/images/nx18")
let assets = repo.appending(path: "beam/Resources/Assets.xcassets")

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
print("BeamTitle written")
