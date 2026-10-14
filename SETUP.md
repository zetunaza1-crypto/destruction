# Shatter Run: Roblox setup steps

Most of the setup is automated by `tools/roblox_setup.py` (uploads, passes, products,
server settings, IDs in the game, publish). This page lists the few things you have
to click yourself.

## 1. Let Claude use your Roblox key (one time)

Your key is saved in the cloud environment, but it is set up for the wrong address.
It is attached to `create.roblox.com`, the Creator Hub website. The Roblox API is
at `apis.roblox.com`.

1. In the Claude app, open this session's **cloud environment** menu in the title bar and click **Edit**.
2. Under **Network secrets**, find the Roblox key.
3. Change its host from `create.roblox.com` to **`apis.roblox.com`**. Leave the header name as `x-api-key`.
4. Save, then start a **new** session. Settings only apply to new sessions.

(Or add it as an environment variable named `ROBLOX_API_KEY`. The script works either way.)

## 2. Give the key the right permissions (one time)

1. Go to **create.roblox.com/dashboard/credentials** and open the **API Keys** tab.
2. Click your key, then **Edit**.
3. Under **Access Permissions**, add each of these. For each one, pick the **Shatter Run** experience and tick the operations:
   - **assets**: Read, Write
   - **universe**: Write
   - **universe-places**: Write
   - **game-passes**: Read, Write
   - **developer-products**: Read, Write
4. Click **Save & Generate Key** only if it asks. If it gives you a new key, update the secret from step 1.

## 3. Send Claude the experience IDs

1. Go to **create.roblox.com/dashboard/creations**.
2. Hover over the Shatter Run tile, click **⋯**, then **Copy Universe ID**. Paste it to Claude.
3. Click the tile, then **Places** on the left, then the start place. The number after `/places/` in the address bar is the **Place ID**. Paste it to Claude.

Claude then runs:

```
python3 tools/roblox_setup.py --universe <UNIVERSE_ID> --place <PLACE_ID>
```

## 4. Things Roblox only lets you do on the website

Go to **create.roblox.com/dashboard/creations**, click Shatter Run, then:

**Icon and thumbnails**
1. In the left menu, open **Configure** > **Basic Settings** (the page with the name and description).
2. **Icon**: click **Upload** and choose `assets/images/icon_512.png`.
3. **Thumbnails**: click **Upload** and add `assets/images/thumbnail_1.png` and `thumbnail_2.png`.
4. Click **Save Changes**.

**Maturity & compliance questionnaire**
1. **Audience** > **Maturity & Compliance**.
2. Answer the questions. Shatter Run has no violence against people, no blood, no romance, no gambling, no chat beyond Roblox's normal chat, and no real-world brands. It is just smashing glass, so it should come out as **Minimal**.
3. **Submit**.

**Genre**
1. **Configure** > **Basic Settings** (or **Audience**).
2. Set **Genre** to **Action** (or **Obby & Platformer** if Action is missing). Set **Subgenre** to **Arcade** if offered.
3. **Save Changes**.

**Make it public** (do this last, after the questionnaire)
1. Back on **Creations**, hover the Shatter Run tile and click **⋯**.
2. Click **Make Public**. You can also do it from **Configure > Basic Settings > Visibility**.

## 5. If creating passes/products by script fails

Those Roblox APIs are still in beta. If the script stops at step 3 or 4, create them by hand:

**Game passes**: Creations > Shatter Run > **Monetization** > **Passes** > **Create a Pass**.
Upload the image, type the name and description, click **Create Pass**. Then click the pass,
go to **Sales**, turn **Item for Sale** on, set the price, and click **Save Changes**.

| Name | Price (R$) | Image | Description |
|---|---|---|---|
| VIP | 149 | pass_vip.png | Start every run with 15 extra balls and earn 2x gems. |
| Multiball | 99 | pass_multiball.png | Your multiball never drops below x2. |
| Checkpoints | 199 | pass_checkpoints.png | Start from any checkpoint you have reached. |

**Developer products**: Creations > Shatter Run > **Monetization** > **Developer Products** > **Create a Developer Product**.
Upload the image (if any), type the name, description and price, then click **Create Developer Product**.

| Name | Price (R$) | Image |
|---|---|---|
| Revive | 25 | product_revive.png |
| Ball Pack | 15 | product_ballpack.png |
| Gem Pack | 49 | product_gempack.png |
| Big Gem Pack | 99 | product_gempack.png |
| Huge Gem Pack | 199 | product_gempack.png |
| Starter Pack | 49 | product_gempack.png |
| Season Pass Premium | 199 | none |
| Shield Boost | 10 | none |
| Magnet Boost | 10 | none |
| 2x Gems Boost | 15 | none |
| Mega Ball Boost | 15 | none |
| Slow-Mo Boost | 10 | none |
| Gem Top-Up | 15 | product_gempack.png |
| Extra Reroll | 5 | none |
| Streak Saver | 15 | none |

Use **exactly these names**. When you run the script again, it finds them by name and
uses their IDs instead of making duplicates.
