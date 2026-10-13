# Shatter Run — notes for Claude

Roblox game (Luau, synced with Rojo). The owner is new to coding: explain changes in plain language, keep code simple and well-named.

## What the game is
First-person on-rails glass smasher inspired by the *gameplay* of the mobile game Smash Hit. Keep all names, art, level layouts, and audio original (no Smash Hit assets/branding) to avoid copyright takedowns.

## Architecture
- Runs are **client-side**: each player's device builds its own track (`src/client/TrackBuilder.luau`) far above the lobby at `Config.TRACK_ORIGIN`, so players don't see each other's runs.
- The server only receives `RunStarted(checkpoint)` and `RunEnded(meters)` and sanity-checks distance against elapsed time (`src/server/Main.server.luau`). Gems are computed server-side.
- Player progress lives in DataStore `PlayerData_v1` and is mirrored to player attributes (`Best`, `Gems`, `Checkpoint`, `OwnedSkins` JSON, `EquippedSkin`, `NextDaily`, `Pass_<Key>`), which the UI reads.
- Developer products: server `ProcessReceipt` → `PurchaseGranted` remote → client adds balls / revives. `GemPack` is granted on the server.
- `UI.luau` has a fixed API used by `RunController.luau` (`showMenu`, `showHud`, `setHud`, `showGameOver`, `hideRevive`, `toast`, `flashDamage`, `setTheme`, `isMenuOpen`). Keep that contract when editing either side.
- UI style: "glass lab / blueprint" look — paper-white panels, ink hairlines, one zone accent color, sharp corners (no UICorner), Michroma + RobotoMono. Avoid generic rounded dark cards and emoji.
- All tuning in `src/shared/Config.luau`. IDs left at 0 disable that feature.

## Roblox account / uploads
- Owner's Roblox user ID: 1875004714 (creator for Open Cloud asset uploads).
- A Roblox Open Cloud key is stored as the environment secret `ROBLOX_API_KEY` (assets read/write). Use it to upload `assets/sounds/*` and `assets/images/*`, then put the resulting asset IDs into `Config.Sounds` and rebuild `ShatterRun.rbxlx`. Never print the key.

## Building
The owner works from cloud sessions only (no local Rojo/Studio connection). After code changes, rebuild the ready-to-open place file and commit it:
`rojo build place.project.json -o ShatterRun.rbxlx` (Rojo 7.4.4 binary from github.com/rojo-rbx/rojo releases). `place.project.json` = `default.project.json` + Baseplate/SpawnLocation.

## Checking code
No Roblox runtime here. Syntax-check Luau with `luau-compile <file>` (download from github.com/luau-lang/luau releases if missing). Test gameplay in Roblox Studio via `rojo serve`.

## Status / next ideas
- Done: zones 0–4 + endless, glass/door/spinner/moving/grid obstacles, multiball, revive, passes, gem shop skins, daily reward, global top 10, ElevenLabs audio in `assets/sounds/` (needs uploading + IDs in Config).
- Ideas: thumbnail/icon art, more zone themes, power-ups (slow-mo, big ball), friend races / ghost runs, seasonal events.
