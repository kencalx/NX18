# NX 18 Beam

NX 18 Beam is NX 18's Mac app. It builds your **legally owned and acquired** games into apps for your iPhone, iPad and Mac, installs them, and plays them on the Mac. Beam includes no games, keys or firmware. It never says where to get them, and NX 18 hosts no mods.

Beam runs NX 18's own build script and relies only on what [docs/frontends.md](frontends.md) promises. Developers build Beam from [beam/](../beam/README.md).

## Getting started

1. **Open Beam.** The welcome screen finds your NX 18 folder (`~/NX18` by default). It also asks whether Beam may check for its own updates once a day. That is off unless you turn it on. When an update is out, Beam says so at the top of its window. **Install and Relaunch** downloads it, checks that it is the real, notarized NX 18 Beam, swaps it in and opens it again (Beam waits while a build or install is running).
2. **Add a game:** drop a folder of your game's files, a `.nup` or an `.nx` on the window or the Dock icon, or choose one. Your files stay where they are. NX 18 reads each game and shows:
   - its name and system;
   - its versions with their build IDs;
   - its DLC;
   - whether NX 18 has tested it.
3. **Profile:** create the name and picture your games show, or use your profile from the NX 18 folder in iCloud Drive (Beam finds the folder; you can choose another), or do it later in Settings › **Profile**. Beam keeps it on this Mac for the games you play here, and puts it in every game it installs on your iPhone or iPad, and in the IPA it makes for other install tools. Connect the same NX 18 folder in Beam and in your games on iPhone or iPad (each game asks once) to share your profile, cloud saves and captures: change your profile on one, and the others pick it up.
4. **Coming from NX Play?** "Bring Your NX Play Library" adds NX Play's games where they are. Nothing is moved or deleted.
5. **Keys:** for games in NSP or XCI form, choose your keys file in Settings. Use the keys dumped from your own console. Beam keeps only the file's location.

## Building and playing

- **Build:** "Build for iPhone and iPad" or "Build for Mac" shows each step, the time left and the messages.
  - Beam checks the disk space first.
  - On battery, it offers to wait for the power adapter.
- **When NX 18 updates:** a game built with an older NX 18 shows **Update available: rebuild** in the library and on Beam Home. Beam marks only the games the update changes: every game when NX 18's shaders changed, else the games whose own NX 18 settings changed, or every game when the code that goes into each app did (an update to the docs or to Beam marks none).
  - **Rebuild updated games** (below the games, or File > Rebuild Updated Games) builds them three at a time, each for the same device and version as before, and keeps the Mac awake until they are done.
  - **File > Rebuild Updated Games Tonight** does it once, at 1 AM. Until then the Mac does not go to sleep on its own (its display does); on battery the builds wait for the power adapter.
- **Play:** a Mac build plays at once, without the game's settings window (Y in Beam Home, or right-click the game › Game Settings…, has them before you play). As it starts, Beam's dashes sweep across the screen and the game comes up; with Reduce Motion on, the screen just fades. In the game's menu, More › **Exit and return to Beam** (asked first) quits the game and brings Beam back to the front.
  - While it plays, Beam moves builds to background priority.
  - **Beam Home** (View > Beam Home) is the library full screen, for a controller or the arrow keys. The bar at the bottom shows the buttons you can press on each screen, drawn as your controller's own buttons. Without a controller, the letter keys A, B, X, Y and − do the same. The optional menu sounds (Settings) stay quiet while the Mac's "Play user interface sound effects" is off.
  - In Beam Home, your profile chip (or − on the controller) opens your profile; B closes it.
  - **Album** (the Album button at the top of Beam Home, or your controller's capture button) shows the screenshots and recordings from all your games, grouped by game, newest first. The D-pad moves, A opens one, B goes back.
- **Settings:** a Mac build's settings open in Beam, on the same panel as the game's own window. With an NX 18 folder connected, a Mac game with no cloud-save folder of its own keeps its save in the NX 18 folder, the same file your iPhone or iPad uses: the **Cloud saves** door says **NX 18 folder**, and the game's page says where its save lives. To switch a game between the NX 18 folder and its own folder, use **This game's saves** on the NX 18 card in the game's own window, which moves the save first. The first time a game syncs through a folder on this Mac, **Play** may show *Checking iCloud for this game's save…* for a moment before the game opens, while iCloud brings the save from your other devices; if it cannot, the game starts with this Mac's save and syncs at a later start.

## iPhone and iPad

- **With Xcode:** add your Apple Developer account in Xcode > Settings > Apple Accounts. Beam signs with it and installs over the cable or the network, and never asks for your password.
- **With your own certificate:** add your Apple Developer certificate (`.p12`) and a profile made for it in Settings. macOS asks for the certificate's password in its own window.
- **Memory limits:** every game is installed with the Increased Memory Limit and Extended Virtual Addressing, or not at all. A free Apple account (Personal Team) cannot have them. With a free account, install the IPA with another tool and add the limit with GetMoreRam; Beam's Step by Step shows how.
- **On the game's page:** each install shows its days left and a Renew button.
- **Before an install expires:** the game's tile and its row in the library say so from 2 days before ("Expires tomorrow on iPhone"). Beam also sends one notification the day before.
- **Renew All** (the library's toolbar, View > Renew All, or X in Beam Home) renews every game about to expire on the devices connected now, one after the other. It names any device that isn't connected.
- **Your profile goes with every install:** the game starts with your name and picture. Installing again after you change your profile on the Mac brings the new one; a change you made on the device since is kept. Each game still asks once for the NX 18 folder, to share it from then on.

## Mods, cheats, art and guides

- **Mods:** frame-rate and Ultrawide code patches only.
  - They come from sources you add ([the format](beam-sources.md)), or from a file you got yourself.
  - Beam checks each one against your game's exact build and credits its author.
  - The launcher's switches turn a mod on and off.
- **Cheats:** your own cheat files, named after the game's build. Beam never downloads cheats.
- **Art:** with a SteamGridDB key, which is kept in the Keychain and never given to the build, choose key art, a logo and an icon. **Adjust Framing…** under the key art chooses which part of it the Gate shows (key art is usually wider than the Gate's space): drag the picture or use the arrow keys, pinch on a trackpad or press + and − to zoom, **Reset** goes back to the middle. The sheet frames it on the iPhone's shape and shows the iPhone upright, iPad and Mac window shapes beside it. Beam Home's backdrop and the game's page use it at once, a Mac app's window at its next start, and an iPhone or iPad from its next build; a framing made in the game's own Gate comes first there. Choosing new key art opens the framing for it. Framing is offered once there is key art the game will be built with: your pick, or the art its last build used.
- **Manual and My files:** add the game's manual to the app. Keep your own guides on the Mac and send them to a device Beam installed on (a file still downloading from iCloud waits: Beam says how many and asks iCloud for them). Keep apps with a manual to your own devices.
- **Keep My files in the NX 18 folder:** turn this on in Settings › **Profile** and your own guides and maps for each game move into the NX 18 folder in iCloud Drive (in the game's folder, under **Documents**, next to its **Captures**). Your games on every iPhone, iPad and Mac connected to that folder can then show them while you play (in-game menu › **Manual & documents**, [Playing](playing.md#manual--documents)), with no need to send them. Turn it off and Beam brings back the files it put there, also from a folder you connected before (while it's still there); files you or another Mac added to the folder stay there for your other devices. Beam never replaces a file: if the name is taken, the new one gets a " 2". The game's page says where its files are.
- **Album:** each game's screenshots and recordings, sorted by day (Today, Yesterday, then by date), newest first, with your own guides and maps (Add Files…) below them. Captures come from the Mac app's own folder and, for iPhone and iPad, from the iCloud NX 18 folder once **This game's captures** is set to **NX 18 folder** on the game's NX 18 card ([Screenshots](playing.md#screenshots)). Click a capture to open it: the arrow keys move to the next or previous one, Return or Space plays or pauses a recording, and the buttons below share it, show it in Finder or move it to the Trash (Beam asks first; Put Back in the Trash brings it back). **Trim** on a recording keeps the part between two handles and saves it as a new recording beside the original ("… trimmed.mov"); the original is never changed. A capture still in iCloud shows a cloud and downloads only when you open it. Click a guide or map to look at it in Quick Look. Beam reads the folders when you open the page and when you come back to Beam, so it does no work while you play. Small thumbnails are kept in Beam's caches folder (`~/Library/Caches/org.nx18.beam/Album Thumbnails`); the oldest are removed when there are many. Beam reads the NX 18 folder connected in Settings › **Profile** (the one your Mac game apps use); with none connected it finds the iCloud Drive folder that holds a Profile, else iCloud Drive › NX 18.

## Privacy

- **Network:** Beam goes online only when you ask: to read a mod source, get a mod, choose art, or check a device. The one exception is the daily update check, and only if you turn it on.
- **What it sends:** requests carry a generic name and nothing about you or your Mac.
- **Where things are kept:**
  - the library: `~/Library/Application Support/NX 18 Beam/`;
  - secrets: the Keychain;
  - your game files: where they always were.
