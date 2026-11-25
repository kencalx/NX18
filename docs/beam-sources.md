# Beam mod sources

NX 18 Beam, NX 18's Mac app, can get mods from **sources**. A source is a JSON file that a mod's author or maintainer publishes at an HTTPS address. A player adds a source to Beam by its address.

- Beam ships with no sources. NX 18 hosts no mods and lists no sources.
- Beam takes only **frame-rate** and **Ultrawide** code patches. These change a game's own code and carry none of its data: no textures, models, audio or RomFS files.
- Mods are for the player's legally owned and acquired games.

This page is the format, version 1.

## The file

```json
{
  "beam_source": 1,
  "name": "Example Patches",
  "maintainer": "Author name",
  "homepage": "https://example.org/patches",
  "mods": [
    {
      "id": "example.game.60fps",
      "title_id": "0100000000010000",
      "build_ids": ["0123456789ABCDEF"],
      "kind": "framerate",
      "variant": "60 fps",
      "version": "1.3",
      "author": "Author name",
      "license": "MIT",
      "homepage": "https://example.org/patches/game",
      "download": "https://example.org/patches/game-60fps-1.3.zip",
      "sha256": "<64 hex digits of the download>",
      "size": 4096,
      "notes": "Needs version 1.2.0"
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `beam_source` | The format version: `1`. Beam refuses a newer version it does not read. |
| `name`, `maintainer`, `homepage` | Shown to the player before they save the source. |
| `mods[].id` | Unique within the source. |
| `mods[].title_id` | The game's title ID, 16 hex digits. |
| `mods[].build_ids` | The builds the mod is for: the first 16 hex digits of main's build ID, as cheat files name them. NX 18's `--identify` shows each version's build. |
| `mods[].kind` | `framerate` or `ultrawide`. Beam does not show any other kind. |
| `mods[].variant` | For a frame-rate mod, its rate, such as `60 fps`. |
| `mods[].author`, `license`, `homepage`, `version` | The credit shown beside the mod. Without `license`, Beam shows "License not stated". |
| `mods[].download` | An HTTPS address of a `.zip` of the patch files, or of one patch file. |
| `mods[].sha256` | The SHA-256 of the download. Beam keeps the mod only when it matches. |
| `mods[].size`, `notes` | Optional. Shown to the player. |

## What Beam checks

1. **The build:** a mod is offered only when one of its `build_ids` is the build of the game version the player builds. A mod for another build is listed greyed ("For another version of the game").
2. **The download:** HTTPS only, straight from `download`, and its SHA-256 must match.
3. **The contents:** only `.ips`, `.ips32` and `.pchtxt` patch files, plus a readme or license as `.txt` or `.md`.
   - Beam refuses a mod with anything else: a `romfs` folder, a whole code module, an executable, a link, a file outside the archive's folder, or one that is too large.
   - The patches must name the game's build. That is an IPS file's name, or a `.pchtxt` file's `@nsobid-` line.
4. **The packer still decides:** at the build, NX 18 applies the patch for the packed version and leaves out what an iPhone cannot run (a code cave, for example). It also refuses a patch that clashes with NX 18's own fixes. Beam shows that verdict after the build.

## How a mod is kept and used

- **Storage:** Beam keeps each game's mods in its own folder, `~/Library/Application Support/NX 18 Beam/Mods/<title ID>/`. It never uses a `mods` folder beside the player's game files.
- **Folder names:** each mod's folder is named for its kind, `60 FPS - <author>` or `Ultrawide - <author>`. That is how the packer recognises a switchable mod.
- **Credit:** a `beam-mod.json` file beside each mod records its source, author, license, homepage, version, SHA-256 and the date added.
- **Building:** Beam passes the folder to the build with `--mods`. In the game, the launcher's **High frame rate** and **Ultrawide** switches turn the mod on and off at each start. A mod is never written into the game for good.
- **Saves:** before the first start of a Mac game after a mod change, Beam copies its save.

## Network

Beam reads a source only when the player adds it, opens a game's Mods, or presses **Check for Mod Updates**. It does not check in the background. Its requests carry a generic client name (`NX18-Beam`) and nothing that identifies the player or the Mac.

## For source maintainers

Publish only mods you made or may share. Name the author and license, and link to the author's own page. A source must not link to game files, keys or firmware, or to where they can be found.
