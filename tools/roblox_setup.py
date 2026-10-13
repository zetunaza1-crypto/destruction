#!/usr/bin/env python3
"""
Shatter Run - one-command Roblox setup (Open Cloud).

What it does, in order (each step is skipped if it was already done, so it is
safe to run again):
  1. Uploads the chosen sounds from assets/sounds        -> Config.Sounds
  2. Uploads every model in assets/models (*.fbx)        -> Config.Models
  3. Uploads every ball model in assets/balls (*.fbx)   -> Config.BallModels
     (premium Robux balls, earned balls like Infinity / Smashbot AND gem-shop
     balls like Grinny)
  4. Creates the game passes (with their images)         -> Config.GamePasses
  5. Creates the developer products (with their images)  -> Config.Products
     (incl. the premium balls, icons assets/images/ball_<id>.png; never the
     earned balls in EARNED_BALLS - those are rewards, not for sale - and never
     the gem-shop balls in GEM_BALLS - those are bought with gems only)
  6. Applies the experience + server settings (name, description, 20 players
     per server, devices, voice chat off, private servers off)
  7. Writes all the IDs into src/shared/Config.luau, and regenerates
     src/shared/BallStyles.luau from assets/balls/manifest.json
  8. Rebuilds ShatterRun.rbxlx with Rojo
  9. Publishes ShatterRun.rbxlx to the place

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
import hashlib
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
BALL_MANIFEST = os.path.join(ROOT, "assets", "balls", "manifest.json")
BALL_STYLES_FILE = os.path.join(ROOT, "src", "shared", "BallStyles.luau")
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
    "Swing": "swing_1.mp3",
    "Reload": "reload_1.mp3",
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
    "SeasonPremium": ("Season Pass Premium", "Unlock the premium rewards of Season 1 (ends 15 Dec 2026). Already premium? You get 3,200 gems instead.", 199, "product_season.png"),
    "BoostShield": ("Shield Boost", "Your next crash is free. Not used this run? It goes back to your boosts.", 10, "product_shield.png"),
    "BoostMagnet": ("Magnet Boost", "Crystals fly to you for 20 seconds.", 10, "product_magnet.png"),
    "BoostDoubleGems": ("2x Gems Boost", "Double gems for one run.", 15, "product_doublegems.png"),
    "BoostMegaBall": ("Mega Ball Boost", "Your next 10 throws are giant. If you use none of them this run, it goes back to your boosts.", 15, "product_megaball.png"),
    "BoostSlowMo": ("Slow-Mo Boost", "Slow down time for 8 seconds.", 10, "product_slowmo.png"),
    "GemTopUp": ("Gem Top-Up", "150 gems.", 15, "product_gempack.png"),
    "ExtraReroll": ("Extra Reroll", "Swap one daily mission for a new one.", 5, "product_reroll.png"),
    "StreakSaver": ("Streak Saver", "Keeps your daily streak going after you missed a day. If your streak is not broken, you get 150 gems instead.", 15, "product_streak.png"),
}

# Premium balls: Config.Skins id -> (name, description, price in Robux).
# Each one is sold as the developer product "Ball<Id>" (icon assets/images/ball_<id>.png)
# and its Blender model assets/balls/<Id>.fbx is uploaded into Config.BallModels.
# Already owned? The game gives price x 16 gems instead (Config.PREMIUM_BALL_REFUND_GEMS_PER_ROBUX).
PREMIUM_BALLS = {
    "Frostbite": ("Frostbite Ball", "An ice core with frost shards circling it. Yours forever. Already own it? You get gems instead.", 79),
    "CyberCore": ("Cyber Core Ball", "A glowing chip inside spinning data rings. Yours forever. Already own it? You get gems instead.", 79),
    "PlasmaCore": ("Plasma Core Ball", "Crackling plasma trapped in a force field. Yours forever. Already own it? You get gems instead.", 99),
    "MagmaHeart": ("Magma Heart Ball", "A molten heart in a cracked rock shell. Yours forever. Already own it? You get gems instead.", 99),
    "BlackHole": ("Black Hole Ball", "Pure darkness with a blazing spinning disk. Yours forever. Already own it? You get gems instead.", 149),
    "Supernova": ("Supernova Ball", "A star about to explode, with blazing rings. Yours forever. Already own it? You get gems instead.", 199),
}

# Earned animated balls (Config.Skins entries with Animated = true): their models are
# uploaded into Config.BallModels like the premium ones, but they are rewards
# (Infinity: reach ZONE 50, Smashbot: smash 50,000 glass) and are NEVER sold, so no
# developer product or game pass is ever made for them.
EARNED_BALLS = ("Infinity", "Smashbot")
assert not set(EARNED_BALLS) & set(PREMIUM_BALLS), "an earned ball must never be sold"

# Animated balls bought in the game's shop with GEMS (Config.Skins Price > 0, e.g.
# Grinny for 25,000 gems). Their models are uploaded into Config.BallModels like the
# others, but they are never sold for Robux: no developer product or game pass.
GEM_BALLS = ("Grinny",)
assert not set(GEM_BALLS) & set(PREMIUM_BALLS), "a gem ball must never be sold for Robux"
assert not set(GEM_BALLS) & set(EARNED_BALLS), "a ball is either earned or bought with gems"


def ball_icon(ball_id):
    """assets/images/ball_<id>.png (lowercase id first, then the exact id)."""
    for name in (f"ball_{ball_id.lower()}.png", f"ball_{ball_id}.png"):
        if os.path.exists(os.path.join(ROOT, "assets", "images", name)):
            return name
    return f"ball_{ball_id.lower()}.png"


for _ball_id, (_name, _description, _price) in PREMIUM_BALLS.items():
    PRODUCTS["Ball" + _ball_id] = (_name, _description, _price, ball_icon(_ball_id))
assert not any("Ball" + _ball_id in PRODUCTS for _ball_id in EARNED_BALLS), "an earned ball must never be sold"
assert not any("Ball" + _ball_id in PRODUCTS for _ball_id in GEM_BALLS), "a gem ball must never be sold for Robux"

EXPERIENCE_NAME = "Shatter Run"
EXPERIENCE_DESCRIPTION = (
    "💥 Smash your way through walls of glass! 💥\n\n"
    "🏃 Throw balls to shatter glass as you fly through 10 colorful zones: "
    "🧪 a science lab, 🌃 a neon city, 🏛️ an ancient temple, 🌿 a greenhouse, 🌌 the Void, "
    "❄️ a frozen cave, 🌋 a magma forge, 🐠 a deep aquarium, ☁️ a sky citadel and 💎 the Crystal Core.\n"
    "⚠️ Watch out - every crash costs you balls!\n\n"
    "💎 Collect crystals to earn more balls\n"
    "🎨 Unlock cool ball skins, epic animated balls and shatter effects\n"
    "🧲 Use boosts like Magnet, Slow-Mo and Mega Ball when you need them\n"
    "📅 Daily missions, a 7-day streak and free daily rewards\n"
    "⭐ Level up and climb the season pass\n"
    "🏆 How far can you go? Reach Zone 50 for the legendary Infinity ball!\n\n"
    "📱💻🎮 Works on phone, tablet, computer and console."
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
    for section in ("Sounds", "Models", "BallModels", "GamePasses", "Products", "Done"):
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
    print("\n[1/9] Sounds")
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
    print("\n[2/9] Models")
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


def step_balls(ids):
    print("\n[3/9] Ball models (premium + earned + gem shop)")
    if not os.path.exists(BALL_MANIFEST):
        print("  no assets/balls/manifest.json yet - skipped")
        return
    with open(BALL_MANIFEST) as f:
        manifest = json.load(f)
    for key, info in manifest.items():
        if ids["BallModels"].get(key):
            print(f"  {key}: already uploaded ({ids['BallModels'][key]})")
            continue
        path = os.path.join(ROOT, "assets", "balls", info.get("file", f"{key}.fbx"))
        if not os.path.exists(path):
            print(f"  {key}: {os.path.basename(path)} is missing - skipped")
            continue
        if DRY_RUN:
            print(f"  {key}: would upload {os.path.basename(path)}")
            continue
        kind = "Earned" if key in EARNED_BALLS else "Gem shop" if key in GEM_BALLS else "Premium"
        asset_id = upload_asset("Model", path, f"ShatterRun Ball {key}", f"{kind} ball model for Shatter Run.", "model/fbx")
        ids["BallModels"][key] = asset_id
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
            update_icon(ids, section, key, image, f"{base}/{ids[section][key]}")
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
            if os.path.exists(path):
                files["imageFile"] = (image, read_file(path), mimetypes.guess_type(path)[0] or "image/png")
            else:
                print(f"  {key}: image {image} not found, creating it without one")
        body, ctype = multipart(fields, files)
        result = request("POST", base, body, ctype)
        ids[section][key] = int(result[id_key])
        if "imageFile" in files:
            ids.setdefault("IconHashes", {})[f"{section}.{key}"] = hashlib.sha256(files["imageFile"][1]).hexdigest()
        save_ids(ids)
        print(f"  {key}: {ids[section][key]} ('{name}', {price} R$)")
        time.sleep(0.5)  # stay under the rate limit


def update_icon(ids, section, key, image, item_url):
    """Uploads the item's icon again when its image file changed (or it never had one).
    ids["IconHashes"] remembers which version of each image is on Roblox."""
    if not image:
        return
    path = os.path.join(ROOT, "assets", "images", image)
    if not os.path.exists(path):
        return
    data = read_file(path)
    digest = hashlib.sha256(data).hexdigest()
    hashes = ids.setdefault("IconHashes", {})
    record = f"{section}.{key}"
    if hashes.get(record) == digest:
        return
    if DRY_RUN:
        print(f"  {key}: would upload icon {image}")
        return
    body, ctype = multipart({}, {"imageFile": (image, data, mimetypes.guess_type(path)[0] or "image/png")})
    if try_request("PATCH", item_url, body, ctype) is not None:
        hashes[record] = digest
        save_ids(ids)
        print(f"  {key}: icon updated ({image})")
        time.sleep(0.5)  # stay under the rate limit


def step_settings(ids, universe, place):
    print("\n[6/9] Experience + server settings")
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


# ---------------------------------------------------------------------------
# src/shared/BallStyles.luau from assets/balls/manifest.json
# ---------------------------------------------------------------------------

BALL_MATERIALS = {"Neon", "Glass", "ForceField", "Metal", "SmoothPlastic", "Foil", "Ice", "Basalt", "CrackedLava"}


def _num(value, default=0.0):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    return number if number == number else default


def _fmt(value):
    text = f"{_num(value):.3f}".rstrip("0").rstrip(".")
    return "0" if text in ("", "-0") else text


def _color(rgb, default=(255, 255, 255)):
    """[r, g, b] as 0-1 floats or 0-255 ints -> Color3.fromRGB(...)."""
    if not isinstance(rgb, (list, tuple)) or len(rgb) < 3:
        rgb = default
    values = [_num(v) for v in rgb[:3]]
    if all(v <= 1.0 for v in values):
        values = [v * 255 for v in values]
    r, g, b = (max(0, min(255, round(v))) for v in values)
    return f"Color3.fromRGB({r}, {g}, {b})"


def _axis(axis):
    """Spin axis [x, y, z], already in Roblox space (Y up) in the manifest -> Vector3."""
    if not isinstance(axis, (list, tuple)) or len(axis) < 3:
        axis = (0, 1, 0)
    x, y, z = (_num(v) for v in axis[:3])
    if x == 0 and y == 0 and z == 0:
        y = 1
    return f"Vector3.new({_fmt(x)}, {_fmt(y)}, {_fmt(z)})"


def _pair(values, default):
    if isinstance(values, (int, float)):
        values = (values, values)
    if not isinstance(values, (list, tuple)) or len(values) < 2:
        values = default
    return "{ " + _fmt(values[0]) + ", " + _fmt(values[1]) + " }"


def ball_styles_luau(manifest, source):
    out = [
        "--[[",
        "\tLook + animation of each animated ball's parts (premium + earned), and its trail / particles / light.",
        f"\tGenerated from {source} by tools/roblox_setup.py (write_ball_styles) - edit the",
        "\tmanifest and run it again instead of editing this by hand.",
        "\tParts match the model's part names (<Id>_<Part>). Spin axes are in the ball's own",
        "\tspace (Roblox, Y up). Size = the model's real bounding box at Diameter (studs).",
        "\tsrc/client/BallFx.luau uses this.",
        "\tBallStyles[Id] = { Diameter, Size?, Parts = { [Part] = { Color, Material, Transparency, Spin?, Pulse?, Flicker?, Show? } },",
        "\t                   Fx = { Trail?, Particles = { ... }, Light? } }",
        "\tFlicker = { Hz, Min, Max }: the part's transparency jumps at random between Min and Max",
        "\tabout Hz times a second (lightning arcs).",
        "\tLite = true: a spinning part that cheap 'lite' balls (extra multiball balls) still show, standing still.",
        "\tShow = { Period, From, To, Invert? }: the part is visible only while (time mod Period) is in [From, To),",
        "\tor only OUTSIDE that window with Invert = true (e.g. Grinny's creepy face / cute face). All parts",
        "\tof one ball share one clock, so their windows line up. Flicker only runs while the part is shown.",
        "\tLite balls don't animate: they keep the Invert parts (always shown) and drop the other Show parts.",
        "]]",
        "",
        "return {",
    ]
    for ball_id, info in manifest.items():
        if not isinstance(info, dict) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", ball_id):
            continue
        out.append(f"\t{ball_id} = {{")
        out.append(f"\t\tDiameter = {_fmt(info.get('diameter', 2.0))},")
        size = info.get("size")
        if isinstance(size, (list, tuple)) and len(size) >= 3 and all(_num(v) > 0 for v in size[:3]):
            out.append(f"\t\tSize = Vector3.new({_fmt(size[0])}, {_fmt(size[1])}, {_fmt(size[2])}),")
        out.append("\t\tParts = {")
        for part, style in (info.get("parts") or {}).items():
            if not isinstance(style, dict) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", part):
                continue
            material = style.get("material") if style.get("material") in BALL_MATERIALS else "SmoothPlastic"
            fields = [
                f"Color = {_color(style.get('color'))}",
                f"Material = Enum.Material.{material}",
                f"Transparency = {_fmt(max(0.0, min(1.0, _num(style.get('transparency'), 0.0))))}",
            ]
            spin = style.get("spin")
            if isinstance(spin, dict) and _num(spin.get("rps")) != 0:
                fields.append(f"Spin = {{ Axis = {_axis(spin.get('axis'))}, Rps = {_fmt(spin.get('rps'))} }}")
            pulse = style.get("pulse")
            if isinstance(pulse, dict) and _num(pulse.get("hz")) > 0:
                fields.append(
                    f"Pulse = {{ Min = {_fmt(_num(pulse.get('min'), 1))}, Max = {_fmt(_num(pulse.get('max'), 1))}, Hz = {_fmt(pulse.get('hz'))} }}"
                )
            flicker = style.get("flicker")
            if isinstance(flicker, dict) and _num(flicker.get("hz")) > 0:
                low = max(0.0, min(1.0, _num(flicker.get("min"), 0.0)))
                high = max(0.0, min(1.0, _num(flicker.get("max"), 1.0)))
                low, high = min(low, high), max(low, high)
                fields.append(f"Flicker = {{ Hz = {_fmt(flicker.get('hz'))}, Min = {_fmt(low)}, Max = {_fmt(high)} }}")
            show = style.get("show")
            if isinstance(show, dict) and _num(show.get("period")) > 0:
                period = _num(show.get("period"))
                start = max(0.0, min(period, _num(show.get("from"), 0.0)))
                stop = max(start, min(period, _num(show.get("to"), period)))
                invert = ", Invert = true" if show.get("invert") is True else ""
                fields.append(f"Show = {{ Period = {_fmt(period)}, From = {_fmt(start)}, To = {_fmt(stop)}{invert} }}")
            if style.get("lite") is True:
                fields.append("Lite = true")
            out.append(f"\t\t\t{part} = {{ " + ", ".join(fields) + " },")
        out.append("\t\t},")
        fx = info.get("fx") or {}
        out.append("\t\tFx = {")
        trail = fx.get("trail")
        if isinstance(trail, dict):
            out.append(
                "\t\t\tTrail = { "
                + f"Color = {_color(trail.get('color'))}, Color2 = {_color(trail.get('color2') or trail.get('color'))}, "
                + f"Lifetime = {_fmt(_num(trail.get('lifetime'), 0.3))}, WidthScale = {_fmt(_num(trail.get('widthScale'), 1))}"
                + " },"
            )
        out.append("\t\t\tParticles = {")
        for particle in fx.get("particles") or []:
            if not isinstance(particle, dict):
                continue
            texture = particle.get("texture") if particle.get("texture") in ("sparkle", "smoke", "fire") else "sparkle"
            out.append(
                "\t\t\t\t{ "
                + f'Texture = "{texture}", Color = {_color(particle.get("color"))}, Rate = {_fmt(_num(particle.get("rate"), 10))}, '
                + f"Size = {_pair(particle.get('size'), (0.3, 0))}, Lifetime = {_pair(particle.get('lifetime'), (0.3, 0.6))}, "
                + f"Speed = {_pair(particle.get('speed'), (1, 3))}, LightEmission = {_fmt(max(0.0, min(1.0, _num(particle.get('lightEmission'), 1))))}"
                + " },"
            )
        out.append("\t\t\t},")
        light = fx.get("light")
        if isinstance(light, dict):
            out.append(
                "\t\t\tLight = { "
                + f"Color = {_color(light.get('color'))}, Range = {_fmt(_num(light.get('range'), 8))}, Brightness = {_fmt(_num(light.get('brightness'), 1))}"
                + " },"
            )
        out.append("\t\t},")
        out.append("\t},")
    out.append("}")
    return "\n".join(out) + "\n"


def _sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def write_ball_styles(ids=None, force=False, manifest_path=BALL_MANIFEST, out_path=BALL_STYLES_FILE):
    """Regenerates src/shared/BallStyles.luau from the ball manifest (if there is one).

    Safe to run again and again:
      - if the file already matches the manifest, nothing is written;
      - if the file was edited by hand since it was last generated (no "Generated from"
        header, or it no longer matches what this script last wrote), it is NOT
        overwritten - copy the hand-tuned values into assets/balls/manifest.json first,
        or pass --regen-ball-styles to overwrite it anyway.
    """
    if not os.path.exists(manifest_path):
        print("  no assets/balls/manifest.json - BallStyles.luau left as it is")
        return False
    with open(manifest_path) as f:
        manifest = json.load(f)
    text = ball_styles_luau(manifest, os.path.relpath(manifest_path, ROOT))
    current = None
    if os.path.exists(out_path):
        with open(out_path) as f:
            current = f.read()
    done = ids["Done"] if ids is not None else {}
    if current == text:
        done["ballStylesHash"] = _sha(text)
        print("  src/shared/BallStyles.luau already matches the manifest")
        return False
    if current is not None and not force:
        generated = "Generated from" in current and done.get("ballStylesHash") == _sha(current)
        if not generated:
            print("  WARNING: src/shared/BallStyles.luau was edited by hand and differs from")
            print("  assets/balls/manifest.json - left as it is. Copy the tuned values into the")
            print("  manifest (or run again with --regen-ball-styles to overwrite the file).")
            return False
    if DRY_RUN:
        print("  would regenerate src/shared/BallStyles.luau")
        return True
    with open(out_path, "w") as f:
        f.write(text)
    done["ballStylesHash"] = _sha(text)
    print("  regenerated src/shared/BallStyles.luau")
    return True


def step_config(ids, regen_ball_styles=False):
    print("\n[7/9] Writing IDs into src/shared/Config.luau")
    with open(CONFIG_FILE) as f:
        text = f.read()
    plain = r"(\n\t{key} = )\d+"  # Sounds / Models:   Name = 123,
    table = r"(\n\t{key} = \{{ Id = )\d+"  # Products / passes: Name = { Id = 123,
    for key, value in ids["Sounds"].items():
        text = set_in_block(text, "Sounds", key, value, plain)
    for key, value in ids["Models"].items():
        text = set_in_block(text, "Models", key, value, plain)
    for key, value in ids["BallModels"].items():
        text = set_in_block(text, "BallModels", key, value, plain)
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
    write_ball_styles(ids, force=regen_ball_styles)
    save_ids(ids)


def step_build():
    print("\n[8/9] Building ShatterRun.rbxlx")
    rojo = os.environ.get("ROJO") or shutil.which("rojo")
    if not rojo:
        raise SystemExit("Rojo not found. Install Rojo 7.4.4 or set ROJO=/path/to/rojo.")
    if DRY_RUN:
        print("  would run rojo build")
        return
    subprocess.run([rojo, "build", "place.project.json", "-o", "ShatterRun.rbxlx"], cwd=ROOT, check=True)


def step_publish(universe, place):
    print("\n[9/9] Publishing to Roblox")
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
    parser.add_argument("--regen-ball-styles", action="store_true",
                        help="Overwrite src/shared/BallStyles.luau from the manifest even if it was edited by hand")
    args = parser.parse_args()
    DRY_RUN = args.dry_run

    ids = load_ids()
    step_sounds(ids)
    step_models(ids)
    step_balls(ids)
    if args.assets_only:
        step_config(ids, args.regen_ball_styles)
        step_build()
        print("\nSounds and models (incl. premium balls) done (--assets-only).")
        return
    if not (args.universe and args.place):
        parser.error("--universe and --place are needed (or use --assets-only)")
    ids["Universe"], ids["Place"] = int(args.universe), int(args.place)
    save_ids(ids)

    print("\n[4/9] Game passes")
    create_items(ids, "GamePasses", GAME_PASSES, args.universe, "pass")
    print("\n[5/9] Developer products")
    create_items(ids, "Products", PRODUCTS, args.universe, "product")
    step_settings(ids, args.universe, args.place)
    step_config(ids, args.regen_ball_styles)
    step_build()
    if args.no_publish:
        print("\nSkipped publishing (--no-publish).")
    else:
        step_publish(args.universe, args.place)
    print("\nAll done.")


if __name__ == "__main__":
    sys.exit(main())
