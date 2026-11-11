# Placeholder game guide

A made-up guide with no game content, built the way the console's offline guides are, for the guide viewer's tests and for screenshots meant to be shared
(`dm/ios/Sources/GuideViewer.swift`, `dm/ios/Sources/LauncherGuideFiles.swift`, the Mac app's `MacGuideWindow`). It sits where a game's guide sits in an app
(`html1/html-document/htmlcontents.htdocs/html/USen/index.html`), so `DM_HTML=<this folder>` shows it in the launcher.

What it does as the console's guides do:

- Its pages are 1280x720 (`width=device-width,height=device-height,user-scalable=no`), the menu reaching the bottom edge.
- When `window.nx` exists it cancels every touch (`preventDefault` on touchstart, touchmove and touchend), and its menu items are `javascript:void(0)` links that act only through `onclick`.
- It waits for the `NXFirstPaintEndAfterLoad` event before loading its pictures and setting up.
- It assigns B (back to the menu, or the end from the menu with `nx.endApplet`) and L / R (the previous and next topic) with `nx.footer.setAssign`; its drawn button hints have no handlers.
- Topic 2 is another page (`topic2.html`), whose Back goes back in the history; the menu's Finish ends the guide by going to ` http://localhost/ `.
- The arrow keys move the menu's focus (`document.onkeydown`, keyCode 37-40).

`window.guideLog` records what happened (`ready`, `menu`, `topic1`, `end`, ...) for the tests to read.

To try it by hand in the Simulator, launch the Duo harness (`dm/ios/tests/duo`) with a launcher list and this folder, then tap **Game guide**:

```sh
SIMCTL_CHILD_DM_APP_DM=/path/to/folder/with/launcher.json SIMCTL_CHILD_DM_HTML=$PWD/dm/ios/tests/fixtures/guide \
  xcrun simctl launch "$DEVICE" org.nxnative.DuoHarness
```

The page should fill the height under the header in landscape, whole; a tap on a topic opens it, the header's back button or a swipe from the left edge goes back,
L and R turn the topics, and Finish closes the guide.
