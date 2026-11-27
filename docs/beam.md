# NX 18 Beam

NX 18 Beam is NX 18's Mac app. It builds your **legally owned and acquired** games into apps for your iPhone, iPad and Mac, installs them, and plays them on the Mac. Beam includes no games, keys or firmware. It never says where to get them, and NX 18 hosts no mods.

Beam runs NX 18's own build script and relies only on what [docs/frontends.md](frontends.md) promises. Developers build Beam from [beam/](../beam/README.md).

## Getting started

1. **Open Beam.** The welcome screen finds your NX 18 folder (`~/NX18` by default). It also asks whether Beam may check for its own updates once a day. That is off unless you turn it on.
2. **Add a game:** drop a folder of your game's files, a `.nup` or an `.nx` on the window or the Dock icon, or choose one. Your files stay where they are. NX 18 reads each game and shows:
   - its name and system;
   - its versions with their build IDs;
   - its DLC;
   - whether NX 18 has tested it.
3. **Profile:** create the name and picture your games show, or use your profile from the NX 18 folder in iCloud Drive (Beam finds the folder; you can choose another), or do it later in Settings › **Profile**. Beam keeps it on this Mac for the games you play here, and puts it in every game it installs on your iPhone or iPad. Connect the same NX 18 folder in Beam and in your games on iPhone or iPad (each game asks once) to share your profile, cloud saves and captures: change your profile on one, and the others pick it up.
4. **Coming from NX Play?** "Bring Your NX Play Library" adds NX Play's games where they are. Nothing is moved or deleted.
5. **Keys:** for games in NSP or XCI form, choose your keys file in Settings. Use the keys dumped from your own console. Beam keeps only the file's location.

## Building and playing

- **Build:** "Build for iPhone and iPad" or "Build for Mac" shows each step, the time left and the messages.
  - Beam checks the disk space first.
  - On battery, it offers to wait for the power adapter.
- **Play:** a Mac build plays at once.
  - While it plays, Beam moves builds to background priority.
  - **Beam Home** (View > Beam Home) is the library full screen, for a controller or the arrow keys.
- **Settings:** a Mac build's settings open in Beam, on the same panel as the game's own window.

## iPhone and iPad

- **With Xcode:** add your Apple Developer account in Xcode > Settings > Apple Accounts. Beam signs with it and installs over the cable or the network, and never asks for your password.
- **With your own certificate:** add your Apple Developer certificate (`.p12`) and a profile made for it in Settings. macOS asks for the certificate's password in its own window.
- **Memory limits:** every game is installed with the Increased Memory Limit and Extended Virtual Addressing, or not at all. A free Apple account (Personal Team) cannot have them. With a free account, install the IPA with another tool and add the limit with GetMoreRam; Beam's Step by Step shows how.
- **On the game's page:** each install shows its days left and a Renew button.
- **Your profile goes with every install:** the game starts with your name and picture. Installing again after you change your profile on the Mac brings the new one; a change you made on the device since is kept. Each game still asks once for the NX 18 folder, to share it from then on.

## Mods, cheats, art and guides

- **Mods:** frame-rate and Ultrawide code patches only.
  - They come from sources you add ([the format](beam-sources.md)), or from a file you got yourself.
  - Beam checks each one against your game's exact build and credits its author.
  - The launcher's switches turn a mod on and off.
- **Cheats:** your own cheat files, named after the game's build. Beam never downloads cheats.
- **Art:** with a SteamGridDB key, which is kept in the Keychain and never given to the build, choose key art, a logo and an icon.
- **Manual and My files:** add the game's manual to the app. Keep your own guides on the Mac and send them to a device Beam installed on. Keep apps with a manual to your own devices.
- **Album:** each game's screenshots and recordings, with your own guides and maps (Add Files…), newest first. Captures come from the Mac app's own folder and, for iPhone and iPad, from the iCloud NX 18 folder once **This game's captures** is set to **NX 18 folder** on the game's NX 18 card ([Screenshots](playing.md#screenshots)). Click one to look at it in Quick Look; right-click to open it, show it in Finder, share it or move it to the Trash. Beam reads the NX 18 folder connected in Settings › **Profile** (the one your Mac game apps use); with none connected it finds the iCloud Drive folder that holds a Profile, else iCloud Drive › NX 18.

## Privacy

- **Network:** Beam goes online only when you ask: to read a mod source, get a mod, choose art, or check a device. The one exception is the daily update check, and only if you turn it on.
- **What it sends:** requests carry a generic name and nothing about you or your Mac.
- **Where things are kept:**
  - the library: `~/Library/Application Support/NX 18 Beam/`;
  - secrets: the Keychain;
  - your game files: where they always were.
