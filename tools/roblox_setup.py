#!/usr/bin/env python3
"""
Shatter Run - one-command Roblox setup (Open Cloud).

What it does, in order (each step is skipped if it was already done, so it is
safe to run again):
  1. Uploads the chosen sounds from assets/sounds        -> Config.Sounds
  2. Uploads every model in assets/models (*.fbx)        -> Config.Models
  3. Creates the game passes (with their images)         -> Config.GamePasses
  4. Creates the developer products (with their images)  -> Config.Products
  5. Applies the experience + server settings (name, description, 20 players
     per server, devices, voice chat off, private servers off)
  6. Writes all the IDs into src/shared/Config.luau
  7. Rebuilds ShatterRun.rbxlx with Rojo
  8. Publishes ShatterRun.rbxlx to the place

Every ID it gets back is saved in tools/roblox_ids.json, so a second run never
uploads or creates anything twice.

Usage:
  python3 tools/roblox_setup.py --universe <UNIVERSE_ID> --place <PLACE_ID>
  (add --dry-run to only print what it would do)

The API key is read from the ROBLOX_API_KEY environment variable. If it is not
set, requests are sent without a key header (for cloud sessions where a proxy
adds the key for apis.roblox.com). The key is never printed.
"""

import argparse
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IDS_FILE = os.path.join(ROOT, "tools", "roblox_ids.json")
CONFIG_FILE = os.path.join(ROOT, "src", "shared", "Config.luau")
PLACE_FILE = os.path.join(ROOT, "ShatterRun.rbxlx")
API = "https://apis.roblox.com"
CREATOR_USER_ID = "1875004714"

# ---------------------------------------------------------------------------
# What to upload / create
# ---------------------------------------------------------------------------

# Config.Sounds key -> file. Picked from the two variants of each sound:
# louder, single-hit versions (shatter_1 has a second hit; crystal_2 is very quiet).
SOUNDS = {
    "Throw": "throw_1.mp3",
    "Shatter": "shatter_2.mp3",
    "Crystal": "crystal_1.mp3",
    "Crash": "crash_1.mp3",
    "Checkpoint": "checkpoint_1.mp3",
    "Gift": "gift_2.mp3",
    "Music": "music.mp3",
}

# Config.GamePasses key -> (name, description, price in Robux, image)
GAME_PASSES = {
    "VIP": ("VIP", "Start every run with 15 extra balls and earn 2x gems.", 149, "pass_vip.png"),
    "Multiball": ("Multiball", "Your multiball never drops below x2.", 99, "pass_multiball.png"),
    "Checkpoints": ("Checkpoints", "Start a run from any zone you have already reached. Checkpoint runs do not count for your best distance.", 199, "pass_checkpoints.png"),
}

# Config.Products key -> (name, description, price in Robux, image or None)
PRODUCTS = {
    "Revive": ("Revive", "Keep your run going with 25 more balls. If your run already ended, you get them at the start of your next run.", 25, "product_revive.png"),
    "BallPack": ("Ball Pack", "Get 50 more balls. If you are not in a run, you get them at the start of your next run.", 15, "product_ballpack.png"),
    "GemPack": ("Gem Pack", "500 gems for skins and boosts.", 49, "product_gempack.png"),
    "GemPackMedium": ("Big Gem Pack", "1,200 gems (+20% bonus).", 99, "product_gempack.png"),
    "GemPackLarge": ("Huge Gem Pack", "3,200 gems - best value!", 199, "product_gempack.png"),
    "StarterPack": ("Starter Pack", "1,000 gems, the Starter ball and the Frost shatter effect. One time offer: if you already own the items, you still get the gems.", 49, "product_gempack.png"),
    "SeasonPremium": ("Season Pass Premium", "Unlock the premium rewards of Season 1 (ends 15 Dec 2026). Already premium? You get 3,200 gems instead.", 199, None),
    "BoostShield": ("Shield Boost", "Your next crash is free. Not used this run? It goes back to your boosts.", 10, None),
    "BoostMagnet": ("Magnet Boost", "Crystals fly to you for 20 seconds.", 10, None),
    "BoostDoubleGems": ("2x Gems Boost", "Double gems for one run.", 15, None),
    "BoostMegaBall": ("Mega Ball Boost", "Your next 10 throws are giant. If you use none of them this run, it goes back to your boosts.", 15, None),
    "BoostSlowMo": ("Slow-Mo Boost", "Slow down time for 8 seconds.", 10, None),
    "GemTopUp": ("Gem Top-Up", "150 gems.", 15, "product_gempack.png"),
    "ExtraReroll": ("Extra Reroll", "Swap one daily mission for a new one.", 5, None),
    "StreakSaver": ("Streak Saver", "Keeps your daily streak going after you missed a day. If your streak is not broken, you get 150 gems instead.", 15, None),
}

EXPERIENCE_NAME = "Shatter Run"
EXPERIENCE_DESCRIPTION = (
    "Smash your way through walls of glass!\n\n"
    "Throw balls to shatter glass as you fly through 5 colorful zones: a science lab, "
    "a greenhouse, an ancient temple, a neon city and the Void. Watch out - every crash "
    "costs you balls!\n\n"
    "- Collect crystals to earn more balls\n"
    "- Unlock cool ball skins and shatter effects\n"
    "- Daily missions, a 7-day streak and free daily rewards\n"
    "- Level up and climb the season pass\n\n"
    "Works on computer, phone, tablet and console."
)
SERVER_SIZE = 20

# ---------------------------------------------------------------------------
# HTTP helpers (standard library only)
# ---------------------------------------------------------------------------

DRY_RUN = False


def headers(extra=None):
    h = {"User-Agent": "ShatterRun-setup"}
    key = os.environ.get("ROBLOX_API_KEY")
    if key:
        h["x-api-key"] = key
    if extra:
        h.update(extra)
    return h


def request(method, url, body=None, content_type=None, retries=4):
    extra = {"Content-Type": content_type} if content_type else None
    for attempt in range(retries + 1):
        req = urllib.request.Request(url, data=body, method=method, headers=headers(extra))
        try:
            with urllib.request.urlopen(req, timeout=300) as resp:
                text = resp.read().decode("utf-8", "replace")
                return json.loads(text) if text.strip() else {}
        except urllib.error.HTTPError as err:
            text = err.read().decode("utf-8", "replace")
            if err.code == 429 or err.code >= 500:
                if attempt < retries:
                    time.sleep(2 ** (attempt + 1))
                    continue
            raise SystemExit(f"\n{method} {url}\n-> HTTP {err.code}: {text[:800]}\n{hint(err.code)}")
        except urllib.error.URLError as err:
            if attempt < retries:
                time.sleep(2 ** (attempt + 1))
                continue
            raise SystemExit(f"\n{method} {url}\n-> network error: {err}")


def try_request(*args, **kwargs):
    """Like request(), but prints the error and returns None instead of stopping the script."""
    try:
        return request(*args, **kwargs)
    except SystemExit as err:
        print(f"  SKIPPED: {str(err).strip()}")
        return None


def hint(code):
    if code == 401:
        return "Hint: the API key is missing or invalid (check ROBLOX_API_KEY)."
    if code == 403:
        return ("Hint: the key is missing a permission or this experience. In "
                "create.roblox.com/dashboard/credentials add to the key: assets (read+write), "
                "universe (write), universe-places (write), game-passes (read+write), "
                "developer-products (read+write), and pick the Shatter Run experience for each.")
    return ""


def multipart(fields, files):
    """fields: {name: str}, files: {name: (filename, bytes, content_type)}"""
    boundary = "----shatterrun" + uuid.uuid4().hex
    parts = []
    for name, value in fields.items():
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
        )
    for name, (filename, data, ctype) in files.items():
        parts.append(
            (f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'
             f"Content-Type: {ctype}\r\n\r\n").encode() + data + b"\r\n"
        )
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def read_file(path):
    with open(path, "rb") as f:
        return f.read()


# ---------------------------------------------------------------------------
# Saved IDs
# ---------------------------------------------------------------------------


def load_ids():
    if os.path.exists(IDS_FILE):
        with open(IDS_FILE) as f:
            ids = json.load(f)
    else:
        ids = {}
    for section in ("Sounds", "Models", "GamePasses", "Products", "Done"):
        ids.setdefault(section, {})
    return ids


def save_ids(ids):
    if DRY_RUN:
        return
    with open(IDS_FILE, "w") as f:
        json.dump(ids, f, indent=2, sort_keys=True)
        f.write("\n")


# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------


def upload_asset(asset_type, path, display_name, description, content_type):
    meta = {
        "assetType": asset_type,
        "displayName": display_name,
        "description": description,
        "creationContext": {"creator": {"userId": CREATOR_USER_ID}},
    }
    body, ctype = multipart(
        {"request": json.dumps(meta)},
        {"fileContent": (os.path.basename(path), read_file(path), content_type)},
    )
    op = request("POST", f"{API}/assets/v1/assets", body, ctype)
    # Uploads finish in the background: poll the operation until it is done.
    op_path = op.get("path") or f"operations/{op.get('operationId')}"
    for _ in range(60):
        if op.get("done"):
            break
        time.sleep(2)
        op = request("GET", f"{API}/assets/v1/{op_path}")
    if not op.get("done"):
        raise SystemExit(f"Upload of {path} did not finish in time (operation {op_path}). Run again later.")
    if "error" in op:
        raise SystemExit(f"Upload of {path} failed: {op['error']}")
    return int(op["response"]["assetId"])


def step_sounds(ids):
    print("\n[1/8] Sounds")
    for key, filename in SOUNDS.items():
        if ids["Sounds"].get(key):
            print(f"  {key}: already uploaded ({ids['Sounds'][key]})")
            continue
        path = os.path.join(ROOT, "assets", "sounds", filename)
        if DRY_RUN:
            print(f"  {key}: would upload {filename}")
            continue
        asset_id = upload_asset("Audio", path, f"Shatter Run - {key}", "Sound effect for Shatter Run.", "audio/mpeg")
        ids["Sounds"][key] = asset_id
        save_ids(ids)
        print(f"  {key}: {asset_id}")


def step_models(ids):
    print("\n[2/8] Models")
    with open(os.path.join(ROOT, "assets", "models", "manifest.json")) as f:
        manifest = json.load(f)
    for key, info in manifest.items():
        if ids["Models"].get(key):
            print(f"  {key}: already uploaded ({ids['Models'][key]})")
            continue
        path = os.path.join(ROOT, "assets", "models", info["file"])
        if DRY_RUN:
            print(f"  {key}: would upload {info['file']}")
            continue
        asset_id = upload_asset("Model", path, f"ShatterRun {key}", "Decoration model for Shatter Run.", "model/fbx")
        ids["Models"][key] = asset_id
        save_ids(ids)
        print(f"  {key}: {asset_id}")


def list_existing(url, list_key, id_key):
    """Returns {name: id} for passes/products that already exist (so we never make duplicates)."""
    found, token = {}, None
    while True:
        page = request("GET", url + (f"?pageToken={token}" if token else ""))
        for item in page.get(list_key, []):
            found[item["name"]] = int(item[id_key])
        token = page.get("nextPageToken")
        if not token:
            return found


def create_items(ids, section, items, universe, kind):
    if kind == "pass":
        base = f"{API}/game-passes/v1/universes/{universe}/game-passes"
        existing = {} if DRY_RUN else list_existing(base + "/creator", "gamePasses", "gamePassId")
        id_key = "gamePassId"
    else:
        base = f"{API}/developer-products/v2/universes/{universe}/developer-products"
        existing = {} if DRY_RUN else list_existing(base + "/creator", "developerProducts", "productId")
        id_key = "productId"
    for key, (name, description, price, image) in items.items():
        if ids[section].get(key):
            print(f"  {key}: already created ({ids[section][key]})")
            continue
        if name in existing:
            ids[section][key] = existing[name]
            save_ids(ids)
            print(f"  {key}: found existing '{name}' ({existing[name]})")
            continue
        if DRY_RUN:
            print(f"  {key}: would create '{name}' for {price} R$")
            continue
        fields = {
            "name": name,
            "description": description,
            "isForSale": "true",
            "price": str(price),
            "isRegionalPricingEnabled": "true",
        }
        files = {}
        if image:
            path = os.path.join(ROOT, "assets", "images", image)
            files["imageFile"] = (image, read_file(path), mimetypes.guess_type(path)[0] or "image/png")
        body, ctype = multipart(fields, files)
        result = request("POST", base, body, ctype)
        ids[section][key] = int(result[id_key])
        save_ids(ids)
        print(f"  {key}: {ids[section][key]} ('{name}', {price} R$)")
        time.sleep(0.5)  # stay under the rate limit


def step_settings(ids, universe, place):
    print("\n[5/8] Experience + server settings")
    universe_fields = {
        "voiceChatEnabled": False,
        "desktopEnabled": True,
        "mobileEnabled": True,
        "tabletEnabled": True,
        "consoleEnabled": True,
        "vrEnabled": False,
    }
    place_fields = {
        "displayName": EXPERIENCE_NAME,
        "description": EXPERIENCE_DESCRIPTION,
        "serverSize": SERVER_SIZE,
    }
    if DRY_RUN:
        print(f"  would set universe: {universe_fields}, private servers off")
        print(f"  would set place: name, description, serverSize={SERVER_SIZE}")
        return
    # privateServerPriceRobux is in the mask but not in the body: that turns private servers off.
    mask = ",".join(list(universe_fields) + ["privateServerPriceRobux"])
    ok = try_request("PATCH", f"{API}/cloud/v2/universes/{universe}?updateMask={mask}",
                     json.dumps(universe_fields).encode(), "application/json")
    if ok:
        print("  devices on (computer, phone, tablet, console), VR off, voice chat off, private servers off")
    mask = ",".join(place_fields)
    ok_place = try_request("PATCH", f"{API}/cloud/v2/universes/{universe}/places/{place}?updateMask={mask}",
                           json.dumps(place_fields).encode(), "application/json")
    if ok_place:
        print(f"  name '{EXPERIENCE_NAME}', description set, {SERVER_SIZE} players per server")
    ids["Done"]["settings"] = bool(ok and ok_place)
    save_ids(ids)


def set_in_block(text, block, key, value, pattern):
    """Replace the ID for `key` inside the `Config.<block> = { ... }` table only."""
    start = text.index(f"Config.{block} = {{")
    end = text.index("\n}", start)
    section = text[start:end]
    new_section, count = re.subn(pattern.format(key=re.escape(key)), lambda m: m.group(1) + str(value), section, count=1)
    if count != 1:
        raise SystemExit(f"Could not find {block}.{key} in Config.luau")
    return text[:start] + new_section + text[end:]


def step_config(ids):
    print("\n[6/8] Writing IDs into src/shared/Config.luau")
    with open(CONFIG_FILE) as f:
        text = f.read()
    plain = r"(\n\t{key} = )\d+"  # Sounds / Models:   Name = 123,
    table = r"(\n\t{key} = \{{ Id = )\d+"  # Products / passes: Name = { Id = 123,
    for key, value in ids["Sounds"].items():
        text = set_in_block(text, "Sounds", key, value, plain)
    for key, value in ids["Models"].items():
        text = set_in_block(text, "Models", key, value, plain)
    for key, value in ids["Products"].items():
        text = set_in_block(text, "Products", key, value, table)
    for key, value in ids["GamePasses"].items():
        text = set_in_block(text, "GamePasses", key, value, table)
    if DRY_RUN:
        print("  (dry run, not written)")
        return
    with open(CONFIG_FILE, "w") as f:
        f.write(text)
    print("  done")


def step_build():
    print("\n[7/8] Building ShatterRun.rbxlx")
    rojo = os.environ.get("ROJO") or shutil.which("rojo")
    if not rojo:
        raise SystemExit("Rojo not found. Install Rojo 7.4.4 or set ROJO=/path/to/rojo.")
    if DRY_RUN:
        print("  would run rojo build")
        return
    subprocess.run([rojo, "build", "place.project.json", "-o", "ShatterRun.rbxlx"], cwd=ROOT, check=True)


def step_publish(universe, place):
    print("\n[8/8] Publishing to Roblox")
    if DRY_RUN:
        print(f"  would publish ShatterRun.rbxlx to place {place}")
        return
    result = request("POST", f"{API}/universes/v1/{universe}/places/{place}/versions?versionType=Published",
                     read_file(PLACE_FILE), "application/xml")
    print(f"  published, version {result.get('versionNumber')}")


def main():
    global DRY_RUN
    parser = argparse.ArgumentParser(description="Upload Shatter Run assets and set up the experience.")
    parser.add_argument("--universe", help="Universe ID (Creator Hub: ... > Copy Universe ID)")
    parser.add_argument("--place", help="Start place ID")
    parser.add_argument("--assets-only", action="store_true",
                        help="Only upload sounds + models and write their IDs (no experience needed)")
    parser.add_argument("--dry-run", action="store_true", help="Only print what would happen")
    parser.add_argument("--no-publish", action="store_true", help="Do everything except publishing")
    args = parser.parse_args()
    DRY_RUN = args.dry_run

    ids = load_ids()
    step_sounds(ids)
    step_models(ids)
    if args.assets_only:
        step_config(ids)
        step_build()
        print("\nSounds and models done (--assets-only).")
        return
    if not (args.universe and args.place):
        parser.error("--universe and --place are needed (or use --assets-only)")
    ids["Universe"], ids["Place"] = int(args.universe), int(args.place)
    save_ids(ids)

    print("\n[3/8] Game passes")
    create_items(ids, "GamePasses", GAME_PASSES, args.universe, "pass")
    print("\n[4/8] Developer products")
    create_items(ids, "Products", PRODUCTS, args.universe, "product")
    step_settings(ids, args.universe, args.place)
    step_config(ids)
    step_build()
    if args.no_publish:
        print("\nSkipped publishing (--no-publish).")
    else:
        step_publish(args.universe, args.place)
    print("\nAll done.")


if __name__ == "__main__":
    sys.exit(main())
