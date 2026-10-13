# Premium balls (Blender -> FBX)

Six Robux balls: Frostbite, CyberCore, PlasmaCore, MagmaHeart, BlackHole, Supernova. `preview.png` shows all six.
The store icons are `assets/images/ball_<id>.png` (512x512, lowercase id, for example `ball_supernova.png`).

Two more balls are **earned**, never sold for Robux or gems. `preview_earned.png` shows them both.
- **Infinity** (reward for reaching zone 50): a black core with a spinning purple, blue and pink galaxy under a dark glass shell, two gold "infinity" loops spinning opposite ways, and cyan lightning that flickers.
- **Smashbot** (unlocked after smashing 50,000 glass in total): steel armour plates with orange hazard stripes and rivets that slide out and back to show a glowing orange core, a big cyan eye on the front and back, and an orange gear ring that spins.

One more ball is bought **with gems only** (25,000 gems, the most expensive gem ball, never sold for Robux). `preview_grinny.png` shows its two faces.
- **Grinny**: an original character, a glossy golden-yellow soccer-panel ball (yellow `Panels` over a darker amber `Seams` ball) wrapped in a white `Net`, with torn net strands sticking out like it just ripped out of a goal. Most of the time it has a cute face (`CuteEyes`, `CuteShine`, `CuteSmile`, `Blush`). Every 4 seconds a huge toothy grin (`GrinEyes`, `GrinShine`, `Mouth`, `Teeth`) snaps in for 1.1 seconds, with a cyan offset copy (`Ghost`) and white scan bars (`GlitchBars`) flickering for a moment as it appears. Kid-friendly creepy: no blood, nothing scarier than the grin. The face is on the front (+Z, the side the first-person camera sees). Nothing on Grinny spins or pulses.

- Each `<Id>.fbx` has one empty named `<Id>` and one mesh per part, named `<Id>_<Part>`. There are no textures or materials: the colour, material and transparency of every part are in `manifest.json`.
- The origin is the ball's centre. 1 Blender unit = 1 stud. The bounding sphere is exactly 2.0 studs across. `size` is the box size at rest, in Roblox axes [X, Y up, Z].
- Parts that never move may sit off-centre (Grinny's face parts are on the front only). The game keeps every part where it was imported, so this is fine.
- Every part that moves (it has `spin` or `pulse`) is built symmetric around the centre, so its MeshPart's bounding-box centre is the ball centre. Spinning or scaling a part around its own centre therefore moves it around the ball.
- `spin.axis` is in the ball's Roblox space (Y up). A negative `rps` turns the part the other way.
- `pulse` scales the part uniformly between `min` and `max`, `hz` times per second. Parts with exactly the same `pulse` move together. Smashbot's Plates, Rivets and Stripes share one pulse, so they open and close as one piece of armour.
- `flicker` (optional, only on some parts) makes the part's transparency jump randomly between `min` and `max` (0 = solid, 1 = invisible) about `hz` times per second. Infinity's lightning (`BoltsA`, `BoltsB`) uses it to crackle on and off. Parts without `flicker` keep their normal `transparency`.
- `show` (optional, only on Grinny's face parts) is `{"period": P, "from": A, "to": B}`: the part is visible only while (time mod P) is in [A, B) and hidden the rest of the time. With `"invert": true` inside `show`, it is the other way round: visible only outside [A, B). Every part of one ball uses the same clock, so the windows line up. Grinny's grin parts use period 4.0, from 2.9 to 4.0, and its cute parts use the same window inverted, so exactly one face shows at a time. A part can have both `show` and `flicker`: it flickers only while it is shown (`Ghost` from 2.9 to 3.3, `GlitchBars` from 2.82 to 3.08). A hidden part should be fully invisible (transparency 1), whatever its `flicker` says.
- `lite` (optional, `true`) keeps a spinning part on the cheap "lite" balls (extra multiball balls), standing still. Lite balls normally drop every spinning part, which would leave Infinity as a dark dot, so its galaxy arms, stars and one gold loop (`ArmsA`, `ArmsB`, `Stars`, `RingA`) are marked `lite`.
- Every ball is triangulated with outward normals and stays under 3,000 triangles. Smooth parts have hard edges marked.

The source scripts were scratch files and are not in the repo. `manifest.json` holds everything the game needs.
