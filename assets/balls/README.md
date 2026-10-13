# Premium balls (Blender -> FBX)

Six Robux balls: Frostbite, CyberCore, PlasmaCore, MagmaHeart, BlackHole, Supernova. `preview.png` shows all six.
The store icons are `assets/images/ball_<id>.png` (512x512, lowercase id, for example `ball_supernova.png`).

- Each `<Id>.fbx` has one empty named `<Id>` and one mesh per part, named `<Id>_<Part>`. There are no textures or materials: the colour, material and transparency of every part are in `manifest.json`.
- The origin is the ball's centre. 1 Blender unit = 1 stud. The bounding sphere is exactly 2.0 studs across. `size` is the box size at rest, in Roblox axes [X, Y up, Z].
- Every part that moves (it has `spin` or `pulse`) is built symmetric around the centre, so its MeshPart's bounding-box centre is the ball centre. Spinning or scaling a part around its own centre therefore moves it around the ball.
- `spin.axis` is in the ball's Roblox space (Y up). A negative `rps` turns the part the other way.
- `pulse` scales the part uniformly between `min` and `max`, `hz` times per second.
- Every ball is triangulated with outward normals and stays under 3,000 triangles. Smooth parts have hard edges marked.

The source scripts were scratch files and are not in the repo. `manifest.json` holds everything the game needs.
