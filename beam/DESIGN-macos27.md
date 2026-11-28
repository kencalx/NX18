# Beam and macOS 27's design language

Checked on 2026-11-27 against Apple's macOS 27 UI Kit (Sketch viewer, light and dark). NX 18's own look stays on purpose: the NX18Palette colours, the charcoal Beam Home, the rails, the BeamTitle mark and the console-style Home.

## What the kit shows

| Kit group | What matters for Beam |
|---|---|
| Alerts | Title and text left-aligned, capsule buttons. Two buttons sit side by side: Cancel on the left, the preferred action on the right. Three buttons stack: preferred on top, then destructive (red), then Cancel. The alert sits on the window (window-modal), not floating over the app. |
| Dialogs (save sheet) | Buttons along the bottom: a destructive one alone at the leading edge, then Cancel and the preferred one (blue) at the trailing edge. Form labels right-aligned. |
| Buttons | Capsules. Heights: mini 16, small 20, regular 24, large 28, extra large 36. Bordered, prominent and destructive variants. |
| Windows, Sidebars | Inset glass sidebar with the toggle button beside the traffic lights. Small grey section headers, tinted row symbols, a rounded grey selection, counts at the trailing edge. |
| Titlebars and Toolbars | Toolbar items grouped in glass capsules, 24 pt per item. |
| Forms | Grouped forms: label leading, control trailing; switches for on/off settings; pop-up buttons, steppers and text fields trailing. |

## Beam, screen by screen

| Screen | Checked | Changed |
|---|---|---|
| Library window: sidebar, toolbar | System `NavigationSplitView`, `List` sidebar and `.toolbar`: the system draws the glass sidebar, the selection and the toolbar capsules. Rebuild bar is a `.glass` button. | Nothing. |
| Game page | Floating buttons are one `GlassEffectContainer` of `.glass` / `.glassProminent` buttons; GroupBoxes; semantic fonts; the art runs under the sidebar with `backgroundExtensionEffect`. The scroll edge effect under the toolbar is the system's. | Nothing. |
| Game Settings sheet | Asked "Reset all settings?" and "Turn off cloud saves?" with an app-modal `NSAlert`; Done was at the top. | Uses SwiftUI's `.alert` on the sheet (window-modal); Reset is marked destructive; Done moved to the bottom trailing edge. |
| Settings window | `Form` with `.formStyle(.grouped)`, switches, `LabeledContent`, pickers: matches the kit's forms. | Nothing. |
| Welcome | Hero mark, glass prominent Get Started, a checkbox for the update check (a one-off opt-in, fine as a checkbox outside a form). | Nothing. |
| Add Mod File sheet | Cancel and Add were inside the form as a row. | Now `.cancellationAction` / `.confirmationAction` toolbar items: the system puts them under the form at the trailing edge with Escape and Return. |
| Install with another tool | Done at the top right. | Done moved to the bottom row, trailing, prominent. |
| Bring your NX Play library | Cancel and Bring Them In had no keys. | Escape cancels, Return brings them in. |
| Alerts in the library (Rename, Make room, On battery, Renew All, errors) | System `.alert`; the system orders the buttons. | Nothing. |
| Storage window | A second "Storage" title in the content under the window's own title, Refresh beside it; Move to Trash uses `confirmationDialog` with a destructive role. | Content title removed; Refresh (or the spinner) is in the window's toolbar. |
| Devices | An install's row put Renew (prominent) before Open on Device. | The preferred action now comes last: Open on Device, then Renew. |
| Update banner | Install and Relaunch was plain and before Later. | Later, then Install and Relaunch as the prominent button at the trailing edge. |
| Album (game page) | Context menu with a destructive Move to Trash; Quick Look for files. | Nothing. |
| Album viewer, Beam Home, Profile sheet | Console view: controller hints, glass capsules over art, letter glyphs on buttons. | Nothing (see below). |
| Fixed font sizes | Only on large decorative symbols (empty-state icons, play badges) and the letter in a game's placeholder icon, which scales with the icon. Text uses semantic styles. | Nothing. |

## Calls for the owner

1. **Album viewer's Move to Trash question.** It is a hand-drawn card with "Cancel (B)" and "Move to Trash (A)", and Return confirms the destructive action. The kit and macOS never make a destructive button the default. It is like this so a controller's A confirms in Beam Home. Options: keep it (console feel), or keep the card but make Return do nothing (A still confirms).
2. **Game Settings and Profile sheets are always dark.** They draw NX 18's Gate panel and Profile in the game's own colours even when the Mac is in light mode. Deliberate brand; a light variant would be new work.
3. **Profile sheet over Home keeps Done at the top right** with the controller hints bar at the bottom, as Home's hints work. Moving Done down would collide with the hints bar.
4. **Remove from Library** in the game page's toolbar acts at once with no question. It is safe (the files stay, the game can be added again), so no alert was added; the context menu marks it destructive.
5. **The BeamTitle mark in the game page's toolbar** sits beside the buttons without glass. macOS puts only controls in a toolbar; this is the brand's place, kept on purpose.
6. **Choosing a cloud save folder** in game Settings still opens an app-modal `NSOpenPanel` (it works and is the system's panel); `.fileImporter` would attach it to the sheet. Small, left for a later pass.
7. **App icon grid** (Custom template, 72 x 72 artboards) was not checked here: another branch is converting the icon.
