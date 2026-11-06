# Playing

How to build and install a game: [README](../README.md#how-to-play).

- **Settings:** a screen before the game starts sets frame rate, resolution, docked or handheld mode, language, rumble and more. Tap **Play**; your choices are remembered. What each one does: [Settings](settings.md).
- **Saves and logs** are in the Files app, under the game's name: `save/` and `log.txt` (the previous run is `log.prev.txt`). When something goes wrong, send `log.txt`. When the game closed by itself, also send the newest files in `metrics/` (iOS's own reports of crashes, hangs and runs ended for using too much memory, kept on the device) and `run_layouts.txt`: when iOS hands the app a crash report, at a later start, `log.txt` gets a summary of it (the lines with `crash:`), which names the game code that crashed and, if the High frame rate or Ultrawide toggle was on, says to try that start with it off; the report and `run_layouts.txt` let it be read again in full. **Share log**, on the settings screen and at the bottom of the in-game menu, sends `log.txt`, `log.prev.txt`, `run_layouts.txt` and the five newest `metrics/` files in one go (AirDrop, Mail, Files, …); a run that just crashed is `log.prev.txt` at the next start. It sends a copy, so the game can go on writing its log. On the Mac you build with, `python3 scripts/devlog.py log.txt` sums a log up (frame rate, dropped frames, power, memory, what happened when), and `python3 scripts/devlog.py log.prev.txt log.txt` sets two runs side by side, such as before and after you changed a setting: send that with the logs ([Reading a device log](development.md#reading-a-device-log)).
- **Reinstalling:** some sideloading tools give a reinstalled app a new data folder. Copy `save/` and `pso_user.tsv` over from the old one to keep your progress.

## Touch controls

The gear at the top centre opens the in-game menu (double-tap off the controls to show it; it hides again after 5 seconds): **Controller layout** switches between **2D** and **3D** (and **Tap**, every touch to the game, in handheld mode), and the settings that take effect at once are there too, such as **Picture**, **Console mode** and **Game rumble** ([In-game menu](settings.md#in-game-menu)). The app remembers your choices. Wonder, Engage, Dread, 13 Sentinels, Link's Awakening, Ace Attorney Investigations Collection, Unicorn Overlord, Rhythm Heaven Groove, Octopath Traveler 0, Pokémon Legends: Z-A, Cuphead, Absolum, Blasphemous 2, Brain Memory Training Academy, The Great Ace Attorney Chronicles, STEINS;GATE RE:BOOT, Big Brain Academy: Brain vs. Brain, Patrick's Parabox, Celeste, Raging Loop and Mario vs. Donkey Kong start in 2D, the other games in 3D (STEINS;GATE RE:BOOT's quick save is R3, in the 3D layout).

In 3D, the right stick (the camera in most games) is not drawn: swipe on the right third of the screen, starting anywhere off the buttons. In Super Mario Galaxy and Super Mario Galaxy 2, other touches outside the controls move the pointer; in Captain Toad: Treasure Tracker they touch the game's screen (touch blocks, stun enemies), and in Big Brain Academy: Brain vs. Brain too (its menus and activities).

**Touch control size** (Large, Medium, Small) and **Touch control opacity** (Faint, Light, Normal, Strong), on the settings screen and in the gear's menu, make the controls smaller or more see-through, at once ([Settings](settings.md#touch-control-size)).

A connected game controller hides the touch controls, all but the gear, and keeps every button.

In portrait (an iPad, an iPhone Duo's inner screen) the picture sits above the controls; so it does on a Duo half folded, the picture on the upper half. An iPad game also runs in a window of any size (Stage Manager).

## Cheats

Put an Atmosphère cheat file for the game in the Files app, under the app's name, in the `cheats` folder: named after the game's build ID (`0123456789ABCDEF.txt`), or a Switch SD card's `atmosphere/contents/<title ID>/cheats/` folder. Then open the in-game menu (the gear) › **Cheats** › **Reload cheats**. The same submenu shows the build ID the game looks for, turns each cheat on or off (remembered for the next start) and turns all of them off at once (**Cheats on**). Cheats that rewrite the game's code cannot run on an iPhone or iPad, whose app code is signed; the submenu shows them greyed out with the reason. Pack such patches into the app instead (below). A cheat file packed from the game's mods folder comes back at the next start if you delete it: to stop its cheats, turn off **Cheats on** in the submenu, or set `DM_CHEATS=` (nothing after the `=`, every cheat off) in `Documents/env.txt`.

## Mods and patches

A folder named `mods` beside the game's NSPs is packed into the app: code patches (`.ips`, `.ips32` or `.pchtxt`, such as 60 fps or resolution patches for the version you pack), replacement game files (folders named `romfs`) and cheat files (folders named `cheats`, which the app copies into its `cheats` folder at each start when that folder does not have them; a file already there is kept). Copy them in as Atmosphère, yuzu or Ryujinx lay them out, or a whole SD card's `atmosphere` folder: only this game's are used. Rename a mod's folder to start with `-` to leave it out. `--mods <folder>` names another folder, `--no-mods` packs without them; the build's console lists what it applied ([the packing script](development.md#the-packing-script-in-detail)). A frame-rate or ultrawide mod, named so by its folder (`60FPS`, `Ultrawide`, `21.9`), is not written in for good: the launcher's [High frame rate and Ultrawide](settings.md#high-frame-rate-and-ultrawide) turn it on and off. A patch made for emulators alone, which puts code of its own past the game's code and data (a code cave) or jumps out of the game's code, would end the game on an iPhone, whose app runs only signed code: the build leaves that patch out whole (one `@enabled` block of a `.pchtxt`, or one `.ips` file; of a block that holds the cave and the jump into it beside other changes, only those two) and names it in a red line, and the mod's other patches go in.

## Rumble

Game vibration uses the iPhone's haptic engine or a compatible connected controller. Controllers with separate left/right haptic outputs keep those effects separate. The settings screen's **Game rumble** and **Rumble strength** control it independently of **Touch feedback**. Phone rumble approximates the Switch's effects; physical feel and controller compatibility still need device testing.

## Motion (gyro)

A controller that supplies gyro data through Apple's controller support (DualSense, DualShock 4) drives the game's motion controls, on the Mac and the iPhone: aiming and tilt puzzles in games that read the controller's motion, such as Breath of the Wild with its Motion Controls option on. A controller without one (Backbone One, Razer Kishi and other controllers the phone mounts in) uses the iPhone's own gyro, as a Switch in handheld. Motion follows the controller in docked mode, the default.

`DM_PHONE_MOTION=0` in `Documents/env.txt` stops the phone's gyro, `DM_MOTION=0` all motion. If motion misbehaves, pack with `--no-motion` (`MOTION = False` in Spyder) for an app without it; `DM_MOTION=1` in `Documents/env.txt` turns it back on.

Switch Pro Controller gyro on the Mac still needs the HID support being developed in [PR #296](https://github.com/seedds/nxnative/pull/296).

**Shaking.** Shake the iPhone to shake the controller, in games that read its motion: Super Mario Odyssey's motion moves (such as the cap throw on a shake) need it, and Odyssey only takes them in its default docked mode. A light bump does not count; a sharp flick of the phone does.

## Game language

English by default. Pick another when packing with `--language` (`-l`), by code or by name: `-l ja`, `-l zh-Hans`, `-l French` (`LANGUAGE` in Spyder). It must be one the game has; the script prints the game's languages and stops on one it lacks. To change it without rebuilding, pick another on the settings screen.

## Settings in a file

Lines like `DM_OPMODE=0` (handheld mode: lower resolution, higher frame rate) in `Documents/env.txt` win over the settings screen, which then shows them greyed out ([the full list](settings.md#settings-in-a-file)). `DM_FPS_TARGET=30` keeps Breath of the Wild, Tears of the Kingdom, Octopath Traveler 0 and Octopath Traveler II at their original 30 fps, which saves battery; `DM_PRESENT_INTERVAL=game` does the same for Monster Train 2. `DM_SHOW_FPS=1` shows the frame rate at the top left (`--show-fps` when packing turns it on from the start). `DM_LAUNCHER=0` skips the settings screen.

## On the Mac

A Mac app shows the game's settings in a window before the game starts ([The Mac settings window](settings.md#the-mac-settings-window)). Its `env.txt` is `~/Library/Application Support/nxnative/<title ID>/env.txt`, and its log is `~/Library/Logs/nxnative/<title ID>.log`. [NX2Apple](https://github.com/LNPANDY/NX2Apple)'s library can also start it with the settings you pick there.

A controller macOS pairs but Apple's controller support does not list, such as an 8BitDo in its own mode (Ultimate 2C Wireless over Bluetooth), is read as a raw HID gamepad, with full analog sticks: it takes a player as any other controller does, and the log says `controller '<name>' (HID) connected`. Its buttons follow 8BitDo's numbering by default; another maker's pad may number them differently, and the log then says so. `DM_HID_MAP=A=1,B=2,X=4,Y=5` in `env.txt` moves them (here: the printed letters instead of the positions), `DM_HID_LOG=1` logs the number of each button pressed, and `DM_HID_PADS=0` turns this off.

To quit with a controller, hold its Home button (the logo button on an Xbox or PlayStation controller) for 2 seconds, then press A to quit or B to go back to the game. Quitting this way is the same as ⌘Q: progress the game has not saved is lost. If holding Home opens the Games app instead, macOS keeps the Home button for itself: its controller settings for the Home button decide whether apps may use it. `DM_HOME_QUIT=0` in `env.txt` turns the hold off.

The mouse pointer hides when you press a key or a controller button, or move a stick, while it is over the game picture. Moving the mouse shows it again, as does switching to another window or app.

## Shaders on first sight

Short stutters the first time a new scene appears are normal: the app compiles graphics for it once and remembers them for the next launch. What it remembered, and what the game's list names, is built before the game starts, behind "Preparing shaders" and a progress bar when that takes more than half a second.
