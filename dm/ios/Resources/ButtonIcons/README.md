# Button glyphs of the controller hints

Button Icons and Controls by Zacksly (CC BY 3.0 Licensed | zacksly.itch.io), modified: recoloured.

These are five glyphs from "Switch Button Icons and Controls" by Zacksly, <https://zacksly.itch.io>, licensed under the [Creative Commons Attribution 3.0 Unported License](https://creativecommons.org/licenses/by/3.0/). The licence text that came with the pack is [LICENSE.txt](LICENSE.txt).

| File | Pack file | Used for |
|---|---|---|
| `A.svg` | Buttons Full Solid / White / SVG / A.svg | "Press A to play" on the settings screen; Select in the in-game menu; a lettered pad's A where it is the button to press |
| `B.svg` | … / B.svg | Close beside the guide's and About's close buttons; Back and Close in the in-game menu |
| `X.svg` | … / X.svg | an Xbox-style pad's X, which stands for the Switch's Y (the guide) |
| `Y.svg` | … / Y.svg | the guide button's Y |
| `Plus.svg` | … / Plus.svg | "Press + to play" |

The SVG files are the pack's, unmodified. The apps change them in one way: each glyph is drawn in one of NX 18's colours (coral for Play and for the in-game menu's Close, cyan elsewhere) instead of the pack's white or black.

## How the apps draw them

`dm/ios/tools/button_glyphs.py` reads these SVGs and writes their outlines into `dm/ios/Sources/NXButtonGlyphData.swift`. `dm/ios/Sources/NXButtonGlyph.swift` draws an outline as a SwiftUI shape filled with the surrounding colour, the way a template image takes its tint, so it is sharp at every size and follows Dynamic Type. No image file or asset catalog is needed at run time.

To change a glyph or add one:

1. Copy the pack's SVG here.
2. Add it to `GLYPHS` in `button_glyphs.py` and to `NXButton` in `NXButtonGlyph.swift`.
3. Run `python3 dm/ios/tools/button_glyphs.py` and commit both files.

`dm/ios/tests/test_button_icons.py` checks three things: that the Swift file matches the SVGs, that every SVG here is used, and that the credit is shown where the licence asks.

## Which glyph a hint shows

The hint shows the button the player presses, mapped the way the game maps the controller (`dm/host/pad_apple.h`):

- **Nintendo pad:** the hint follows the pad's printed labels. Switch A is the pad's A.
- **Any other pad:** the hint follows the button's position. Switch A is the right button, so an Xbox pad shows its own B. A PlayStation pad's buttons carry no letters, so its hint shows the pad's own SF Symbol.

The credit appears in three places:

- under the settings screen, next to the version
- in About this game, with the licence's address (creativecommons.org/licenses/by/3.0), since the app does not carry LICENSE.txt
- in the README's Acknowledgements

The Mac app shows no controller hints and does not ship these glyphs.
