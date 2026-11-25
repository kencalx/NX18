# Testing on iPhone Duo

NX 18 has been built and checked for the iPhone Duo in Apple's Simulator only. If you own a Duo, a few short sessions with this checklist tell us what the Simulator can't: how the screens, the hinge and the controls feel on the real device.

## Before you start

- **Your own games only.** Build your apps from games you legally own and acquired, with your own keys, as in [Getting started](getting-started.md). Never share game files, keys, saves or built apps with anyone, including us.
- **Build from the X2.0 preview.** Duo support is in the X2.0 code, not in the current release. Use the branch named in the invitation you received.
- **A Mac** with NX Play or the NSP script, and your Duo on iOS 27.1 or later.
- **One game is enough.** A game you know well is best, so anything that looks wrong stands out.

## The checklist

Do each step with the touch controls, then again with a controller if you have one. Note anything that looks cut off, overlaps, sits under the camera or the fold, or doesn't respond.

**Closed (cover screen):**
1. Open the app. The Gate shows the game's art and the settings side by side. Every tile and the hint line at the bottom read in full.
2. Open Customize and Cloud saves, scroll, and go back, with the ‹ button and with a swipe from the settings panel's left edge.
3. Press Play. The picture fits the screen and the touch controls sit clear of the camera.
4. Open the in-game menu with the button at the top centre. Turn Vitals on and check its line reads.

**Half open (like a small laptop):**
1. While a game runs, open the Duo halfway. The picture moves above the fold and the controls below it.
2. Play for a few minutes. Note any stutter, a picture that doesn't fill its half, or controls you can't reach.
3. Open the in-game menu. Note whether it sits on one half or across the fold.

**Fully open (flat):**
1. Open it flat while the game runs, then hold it in portrait and in landscape. The game keeps running throughout.
2. On the Gate (start the app again), check the art and settings, and that nothing important sits on the fold.

**Folding while playing:**
1. Close and open the Duo several times mid-game, slowly and quickly. The game should keep running, with no freeze, no black screen, and the controls redrawn for the new screen.
2. Do it once with the in-game menu open.

## What to send

Open a [Duo report](https://github.com/kencalx/NX18/issues/new?template=duo_report.yml) on GitHub with:

- **The log.** In the app: Share log (on the Gate, or the gear in the in-game menu). It sends `log.txt` and `log.prev.txt`. Logs record the hinge's changes and never contain keys or game files.
- **Screenshots or a short screen recording** of anything that looks wrong, with the posture it happened in.
- **Your Duo's iOS version**, the game, and the NX 18 commit you built from.

Anything that works well is worth a line too: knowing which steps passed tells us what's done.

Questions while you test, and notes from other testers, are in the [Testing](https://github.com/kencalx/NX18/discussions/categories/testing) category of Discussions.
