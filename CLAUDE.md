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

## Status
Built: 5 themed zones with detailed decor + breakable props, realistic glass shattering, Future lighting with per-zone presets and room lights, levels/XP, daily missions, 7-day streak, season pass (free + premium), boosts (Shield, Magnet, Mega Ball, Slow-Mo, 2x Gems), skins + shatter FX shop, gem packs, starter pack, impulse buys, leave gift, first-run tutorial + one-time tips, settings menu (volume, vibration, graphics Auto/Low/High, shake, flashes), haptics + hit-stop/camera punch, gamepad aiming/navigation, mobile-safe UI, anti-cheat (RoomReached validation), coalesced saves + autosave.
Store art: assets/images (Blender renders). Audio: assets/sounds (ElevenLabs). Models: assets/models (Blender FBX, not yet uploaded).

## Experience & server settings (apply via Open Cloud with ROBLOX_API_KEY)
Runs are client-side and players never see each other, so servers are only for
presence/chat; bigger servers = fewer servers to fill.
- Place serverSize (max players per server): 20.
- Devices: desktop, mobile, tablet, console all enabled (UI + gamepad support built). VR off.
- Voice chat: off (kids audience). Private servers: off for now (or 0 R$ later for friend groups).
- Name "Shatter Run"; description: short, kid-friendly, mention smashing glass, 5 zones, daily rewards.
- Publish ShatterRun.rbxlx to the place via the Place Publishing API instead of asking the owner to republish.
API key permissions needed for this (the owner must add them to the existing key in
create.roblox.com/dashboard/credentials): universe (read/write), universe-places (write),
plus assets (read/write) for uploads. The key's "experience" scope must include the Shatter Run experience.
Owner must do by hand in Creator Hub: maturity/content questionnaire, genre, visibility (public),
icon/thumbnails upload if the API can't (files in assets/images).

## Next session (needs the Roblox key working)
Everything is automated in `tools/roblox_setup.py` (sounds, models, passes, products,
server settings, IDs into Config.luau, rojo build, publish). Saved IDs live in
`tools/roblox_ids.json`, so re-running never duplicates anything. Manual steps for the
owner are in `SETUP.md`.
Blockers found last session:
- The Roblox key is set up as a network secret for `create.roblox.com`, but the API
  lives at `apis.roblox.com`, so calls fail with "Invalid authentication data provided".
  The owner must change the secret's host to `apis.roblox.com` (SETUP.md step 1).
- The universe ID and place ID are unknown. The owner's only public experience is
  "Scorched Earth" (universe 10258084678, place 99548007304061). Don't assume that's
  Shatter Run; ask first, because publishing would overwrite it.
Then run: `ROJO=<path to rojo> python3 tools/roblox_setup.py --universe <U> --place <P>`
(try `--dry-run` first), commit Config.luau + roblox_ids.json + ShatterRun.rbxlx, and send the file.
