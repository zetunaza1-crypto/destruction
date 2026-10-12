# Shatter Run

A first-person glass-smashing runner for Roblox. You glide through corridors, throw metal balls to shatter glass, and collect crystals to keep your ball count up. Run out of balls and the run is over.

## How it plays

- **Tap / click** to throw a ball where you aim. Every throw costs 1 ball.
- **Crash into glass** and you lose 10 balls.
- **Hit crystals** (blue diamonds) for +3 balls. Hit 5 in a row to raise **multiball** (up to x5 balls per throw). Crashing resets it.
- **Red buttons** open metal doors. Miss the button and you crash into the door.
- Every 10 rooms is a **checkpoint**: new zone, new colors, new obstacles, faster speed.

## Project layout

```
default.project.json     Rojo project: maps src/ folders into the game
src/shared/Config.luau   ALL tuning numbers, product/pass IDs, sounds, skins, zones
src/server/              Runs on Roblox servers
  Main.server.luau       Player join/leave, run results, gems, global leaderboard
  PlayerData.luau        Saving & loading progress (DataStore)
  Monetization.luau      Game passes + developer product receipts
  Shop.luau              Buying/equipping skins, daily reward
src/client/              Runs on each player's device
  Main.client.luau       Starts everything
  RunController.luau     The game: camera, throwing, crashes, revive
  TrackBuilder.luau      Builds the corridor rooms and obstacles
  Shatter.luau           Glass breaking + crystal effects
  Sounds.luau            Plays sounds from Config
  UI.luau                All menus and HUD
assets/sounds/           Sound effects + music to upload to Roblox
```

## Easiest way to play (no setup)

1. Download **`ShatterRun.rbxlx`** from this repo (on GitHub: click the file, then the download button).
2. Double-click it. It opens in Roblox Studio with the whole game inside.
3. Press **Play**.

To rebuild that file after code changes: `rojo build place.project.json -o ShatterRun.rbxlx`.

## Setup with live syncing (optional, for editing code)

1. Install [Rokit](https://github.com/rojo-rbx/rokit), then run `rokit install` in this folder to get Rojo.
2. In Roblox Studio install the **Rojo** plugin (Plugins → Manage Plugins, or from the Creator Store).
3. Create a new **Baseplate** place in Studio and save it.
4. In this folder run `rojo serve`, then in Studio click **Rojo → Connect**. The code appears in the game.
5. Press **Play**.

For saving to work in Studio: **Game Settings → Security → Enable Studio Access to API Services** (the game must be published first: File → Publish to Roblox).

## Turning on sounds

1. Pick one file per sound from `assets/sounds/` (there are two versions of each, listen and choose).
2. Upload them in the [Creator Hub](https://create.roblox.com/) → Creations → Development Items → Audio → Import.
3. Copy each audio's asset ID into `Config.Sounds` in `src/shared/Config.luau`.

## Turning on monetization

Publish the game first, then in the Creator Hub open your experience → **Monetization**:

| What | Where | Config key | Suggested price |
|---|---|---|---|
| Revive (+25 balls on game over) | Developer Products | `Config.Products.Revive` | 25 R$ |
| Ball pack (+50 balls mid-run) | Developer Products | `Config.Products.BallPack` | 15 R$ |
| Gem pack (+500 gems) | Developer Products | `Config.Products.GemPack` | 49 R$ |
| VIP (2x gems, +15 balls per run) | Passes | `Config.GamePasses.VIP` | 149 R$ |
| Multiball (never below x2) | Passes | `Config.GamePasses.Multiball` | 99 R$ |
| Checkpoints (start from any zone reached) | Passes | `Config.GamePasses.Checkpoints` | 199 R$ |

Paste each ID into its `Id = 0` slot. Any item left at `0` is hidden in the game, so you can turn them on one at a time.

## Tuning

Everything (speed, ball counts, rewards, zone colors, which obstacles appear in which zone, skin prices) lives in `src/shared/Config.luau`.
