# Prop models (Blender → FBX)
20 low-poly props for the zone corridors: one `.fbx` per model, previewed in `preview.png`.
Each model is a parent empty holding one mesh per color/material role, named `<Model>_<Role>` (Glass, Metal, Wood, Stone, Neon, Plant, Body). There are no textures, so each MeshPart gets its color in Roblox.
`manifest.json` lists each model's file, size in studs `[X, Y up, Z]`, anchor, breakable flag, triangle count, and suggested Color/Material/Transparency for each part.
Origins: floor models sit at bottom-center, ceiling models hang from top-center, and wall models attach at the center of their back face. Fronts face the model's LookVector (-Z).
1 Blender unit = 1 stud. The FBX header declares meters, so if an import comes in at the wrong size, set the size from `manifest.json` (e.g. `Model:ScaleTo`).
Next session: upload each `.fbx` as a Model asset through Open Cloud with the `ROBLOX_API_KEY` secret (creator user 1875004714), then write the asset IDs into Config so Decor/TrackBuilder can place them.
