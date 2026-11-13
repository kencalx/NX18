# Getting started

This page takes you from nothing to playing one of your legally owned and acquired games on your iPhone. Follow it top to bottom. The [README](../README.md#how-to-play) has more detail on each step.

## 1. What you need

- **An iPhone 18** on iOS 27.3 or later. NX 18 is built for the A20 chip (the iPhone 18 family) and tested on an iPhone 18 Pro Max. Older iPhones and older iOS versions are not supported. iPad builds have not been tested.
- **An M-series Mac** (Apple silicon, M1 or later) on macOS 27.3 or later. A virtual Mac isn't supported: its GPU has no Metal 4.
- **Xcode 27.3**, which you download from Apple yourself (step 2 says where).
- **Your legally owned and acquired games**, dumped from your own Switch or Switch 2, and the `prod.keys` dumped from your own Switch for games in `.nsp`, `.xci`, `.nsz` or `.xcz` files. A `.nup` or `.nx` file or a dump folder needs no keys.

NX 18 includes no games, keys or firmware. Everything it builds from comes from your own console and your own purchases.

## 2. Set up your Mac

Download `nx18-setup.sh` and `nx18-build.sh` from the **Assets** of the newest [release](https://github.com/kencalx/NX18/releases). They are also in [`scripts/release`](../scripts/release).

Install Xcode 27.3 first. Download it from [Apple's downloads page](https://developer.apple.com/download/all/?q=Xcode%2027.3) (a free Apple account works), move it to `/Applications`, and open it once. If you already have another Xcode, rename this one `Xcode-27.3.app`. You also need [Homebrew](https://brew.sh); install it yourself, since its installer asks for your password.

Then, in Terminal:

```
bash ~/Downloads/nx18-setup.sh
```

The script checks your Mac, Xcode 27.3 and its Metal toolchain. It installs xcodegen, zstd and the Python modules NX 18 needs, and downloads NX 18 into `~/NX18`. It asks before every install or download, and it never uses `sudo`.

- It ends with **Ready to build.** when everything is in place.
- If something is missing, it says what and how to fix it. Fix it and run the script again: it only does what is still missing.
- `--check` only reports what is missing and changes nothing. `--yes` answers yes to every question.

## 3. Build your game

Rather use an app than Terminal? You can build with NX Play, a community Mac app: see [Build with NX Play instead](#build-with-nx-play-instead) below.

Copy the build script out of Downloads, then open your copy in a text editor:

```
cp -n ~/Downloads/nx18-build.sh ~/nx18-build.sh
```

Edit the **SETTINGS** at its top:

- `GAME`: your legally owned and acquired game files. That's a folder with the game's `.nsp`, `.xci`, `.nsz` or `.xcz` files (with its update and DLC beside them), a dump folder, or a `.nup` or `.nx` file.
- `KEYS`: where your `prod.keys` is, dumped from your own Switch. Only `.nsp`, `.xci`, `.nsz` and `.xcz` games need it.
- `TARGET`: `iphone` (or `ipad` or `mac-app`).

Keep the quotes around each path. Spaces in folder names are fine. Then run it:

```
bash ~/nx18-build.sh
```

The script checks every setting and names the one that's wrong. It picks Xcode 27.3 by itself and keeps your Mac awake while it builds. Your keys stay on your Mac: the script never prints, copies or sends them.

A first build takes 30 to 60 minutes and needs free space of about twice the game's size plus 10 GB. Building again is much faster. When it's done, it says `done in … min:` and where the IPA is (in the game's folder, unless you set `OUTPUT`).

To play on your Mac instead, set `TARGET="mac-app"` and open the app it makes from Finder.

### Build with NX Play instead

NX 18's own Mac app is planned for X2.0. Until then, if you'd rather not use the command line, you can build your games with [NX Play](https://github.com/varyform/nx-native-wrapper), a free community Mac app by Oleh Khomei ([varyform](https://github.com/varyform)), MIT licensed. It can build an IPA or a Mac app, or install the game on your iPhone through Xcode. NX Play is not made by NX 18. It's a suggestion, not a requirement: the steps above stay the documented way.

By default NX Play builds upstream nxnative, not NX 18. To build with NX 18:

1. Do [step 2](#2-set-up-your-mac). It puts NX 18 in `~/NX18`. You can also clone it yourself: `git clone https://github.com/kencalx/NX18.git ~/NX18`.
2. Download NX Play from its [releases](https://github.com/varyform/nx-native-wrapper/releases) and drag it to Applications.
3. In NX Play, open **Settings › General**. At **nxnative repository**, click **Choose…** and pick your `NX18` folder. A green check means it found NX 18's build script. Do this before its Setup installs anything, so it doesn't download upstream nxnative as well.
4. NX Play uses the Xcode your Mac has selected. If you have more than one Xcode, select 27.3: `sudo xcode-select -s /Applications/Xcode-27.3.app`. Leave **Allow a Metal compiler nxnative didn't test** off: it's the build's `--allow-other-metal`, which NX 18 doesn't need with Xcode 27.3.
5. Add your legally owned and acquired games and your `prod.keys` as NX Play's own guide describes.

Before it builds, NX Play brings that folder up to date with NX 18 on GitHub. A release checked out with `nx18-setup.sh --ref <tag>` has nothing to follow, so it stays as it is. Keep your own changes to NX 18 in another folder. NX Play doesn't use `nx18-build.sh`, so the settings above don't apply to it. Questions and bugs about NX Play go to [its own page](https://github.com/varyform/nx-native-wrapper/issues).

## 4. Choose how to install

You install the game on your iPhone with Xcode, or install the IPA with a sideloading tool. Pick one:

| How you install | Apple account | Guides |
| --- | --- | --- |
| **Xcode** (recommended) | Paid Apple Developer account (a free Apple ID works, with the limits below) | [NX 18's Xcode steps](development.md#build-and-run-on-a-device-with-xcode) · [Apple: Running your app on a device](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices) · [Apple: Enroll](https://developer.apple.com/programs/enroll/) |
| **AltStore Classic** | Free Apple ID | [Install on a Mac](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos) · [Install on Windows](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) |
| **SideStore** | Free Apple ID | [What you need](https://docs.sidestore.io/docs/installation/prerequisites) · [Install](https://docs.sidestore.io/docs/installation/install) |
| **Sideloadly** | Free or paid | [sideloadly.io](https://sideloadly.io/) · [FAQ](https://sideloadly.io/faq) |
| **LiveContainer** | Free Apple ID (installed with AltStore or SideStore) | [Installation](https://livecontainer.github.io/docs/installation) |

**Recommended, not required: a paid Apple Developer account.** Apps stay signed for a year instead of 7 days, there's no 3-app limit, and with Xcode the Increased Memory Limit comes through automatically. A free Apple ID works too. Making NX 18 friendlier to free accounts is planned.

The [Apple Developer Program](https://developer.apple.com/programs/) costs 99 USD a year. Apple shows the price in your local currency.

A few things to know:

- **Use AltStore Classic, not AltStore PAL.** Classic installs any `.ipa`. PAL installs only notarized apps ([the difference](https://faq.altstore.io/altstore-pal-v.-altstore-classic)).
- **LiveContainer runs your games inside itself,** so LiveContainer is the app that needs the Increased Memory Limit (step 5).
- **NX Play**, a community Mac app, can also install the game through Xcode, once its settings point at your NX 18 folder ([Build with NX Play instead](#build-with-nx-play-instead)).
- **With Xcode,** keep `TARGET="iphone"` and build with `bash ~/nx18-build.sh --prepare-xcode`. You get an Xcode workspace, `NxNative.xcworkspace` beside the game's folder, instead of an IPA, and Xcode signs and installs the game for you. [NX 18's Xcode steps](development.md#build-and-run-on-a-device-with-xcode) walk you through it.
- **On your iPhone,** turn on **Developer Mode** in Settings › Privacy & Security, then restart and tap **Enable** ([Apple's steps](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)). The switch shows up only after your iPhone has been connected to a computer, so connect it first. With a sideloading tool, also trust the developer profile under Settings › General › VPN & Device Management the first time.
- **A free Apple ID has limits:** 3 apps per device, apps that stop opening after 7 days until you refresh them, and at most 10 App IDs at a time ([Apple's comparison](https://developer.apple.com/support/compare-memberships/)).

## 5. Turn on the Increased Memory Limit

The bigger games need the higher memory limit iOS gives an app with the **Increased Memory Limit**. Without it, iOS may close the game in busy scenes. Every app NX 18 builds asks for it, but whether iOS grants it depends on how you installed:

- **Xcode with a paid account** (or NX Play): nothing to do.
- **Any other way:** follow the steps for your tool in the README's [Increased Memory Limit](../README.md#increased-memory-limit) section.

That section also shows how to check that it worked, from the game's log.

## 6. Keeping it running

- **On a free Apple ID, refresh every 7 days.** Your tool re-signs the game before it expires. In SideStore, tap the **7 DAYS** counter in **My Apps**. Sideloadly can re-sign it for you in the background.
- **Updating to a new build:** install the new IPA over the game already on your phone. **Never delete the game first:** deleting it deletes its data, saves included. Some tools give a reinstalled app a new data folder. If yours does, copy `save/` and `pso_user.tsv` over from the old one ([Playing](playing.md)).
- **Updating NX 18:** run `bash ~/Downloads/nx18-setup.sh` again (or the newer copy from the release). It updates `~/NX18`. When a release changes `nx18-build.sh`, copy your settings into the newer copy. Then build your games again.
- **Back up your saves:** they are in the Files app, under the game's name, in `save/`.
- **Play on more than one device:** cloud saves share one game's save between your iPhone, iPad and Mac through iCloud Drive ([Cloud saves](settings.md#cloud-saves)).

## 7. Common problems

- **The game closes in busy scenes** (no crash message): it doesn't have the Increased Memory Limit. See step 5.
- **The first start takes a long time:** the app builds the graphics pipelines its ready-made set doesn't hold, behind **Preparing shaders**. Later starts reuse them and are faster. Short stutters the first time a new scene appears are normal too ([Shaders on first sight](playing.md#shaders-on-first-sight)).
- **The build stops:** if a setting is wrong, the script's message names it. Otherwise the message says the build stopped, and the reason is in the lines above it. Each step's full output is in the build folder's `logs/`. `bash ~/Downloads/nx18-setup.sh --check` lists missing tools. If you stopped a build, running it again goes on from what is done.
- **The game is too big to install:** set `ROMFS_SEPARATE="yes"` and build again. Then copy the game files to your phone once with the command the script prints. With AltServer, also set `SHADER_FILES="yes"`: AltServer can't install a file of 2 GiB or more.
- **Donkey Kong Bananza stays at 30 fps:** the game picks 60 or 30 fps itself, and on an iPhone it can settle at 30 after a busy scene. Open and close the pause menu to bring it back to 60. This is a known limit.

Still stuck? Open an issue in NX 18's [Issues](https://github.com/kencalx/NX18/issues), with the game's log. [Step 8](#8-reporting-a-problem) says how.

## 8. Reporting a problem

Report a problem in NX 18's [Issues](https://github.com/kencalx/NX18/issues) and attach the game's log:

- **On your iPhone or iPad:** open the in-game menu and tap **Share log**. It sends `log.txt` and `log.prev.txt`, the logs of this run and the one before.
- **On your Mac:** run `python3 scripts/bug_report.py <title ID>` in `~/NX18`. It collects the logs, versions and settings into one file to attach. You can also attach the log files yourself ([README](../README.md#reporting-a-problem)).

Never attach game files, keys or anything extracted from a game. Logs never contain keys or game files. A Mac log can contain your folder names; `bug_report.py` replaces your home folder with `~`.

## 9. Learn more

- [Apple: Choosing a Membership](https://developer.apple.com/support/compare-memberships/): what a free Apple ID can and can't do, and why apps expire after 7 days.
- [Apple: Enabling Developer Mode on a device](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device): the switch every sideloading tool needs.
- [AltStore FAQ: App IDs](https://faq.altstore.io/altstore-classic/app-ids): the 10 App ID limit on a free account, explained.
- [AltStore PAL vs. AltStore Classic](https://faq.altstore.io/altstore-pal-v.-altstore-classic): which AltStore installs your own IPAs.
- [SideStore Docs: Prerequisites](https://docs.sidestore.io/docs/installation/prerequisites): what you need before you install SideStore.
- [Sideloadly FAQ](https://sideloadly.io/faq): the 7-day and 3-app limits, trusting the profile, and Developer Mode.
- [LiveContainer Docs: Installation](https://livecontainer.github.io/docs/installation): which LiveContainer to choose and how to install it.
- [GIGAZINE: How to install SideStore without jailbreak or a Mac](https://gigazine.net/gsc_news/en/20260628-sidestore-sideloading-ios/): a 2026 walkthrough with screenshots, on a Windows PC.
