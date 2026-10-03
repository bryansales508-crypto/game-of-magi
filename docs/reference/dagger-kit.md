# Dagger kit (shelved asset, Bryan 2026-10-03)

**Where:** `assets/dagger-kit-roblox.zip` (934 KB, 30 files). Bryan had the models generated; nothing in the game uses them yet. **Shelved** until the weapons milestone (M10): the goal is randomized daggers players can obtain.

**What's inside** (from the kit's README):
- `blades/Blade_01_Straight.glb` ... `Blade_13_Cleaver.glb`: Straight, Leaf, Kris, Jambiya, Flame, Sawback, Hook, Shard, Stiletto, Fang, Crescent, Lawlab (two woven strands), Cleaver. One mesh each, 56-720 triangles.
- `handles/Handle_01_Classic.glb` ... `Handle_10_Talon.glb`: Classic, Cross, Crescent, Wing, Ring, Twist, Bone, Khanjar, Knuckle, Talon. Each has `_Fittings` (guard, collar, pommel: plain metal, tint with Color), `_Grip` (takes a pattern), and Handle 10 has a `_Gem` (try Neon).
- `patterns/Grip_1_CordWrap.png` ... `Grip_6_SmoothBone.png`: 512x512 grayscale tileable grip textures; the part's Color tints them (SmoothBone is the plain one).
- 13 x 10 x 6 = 780 combinations before colours.

**Assembly rule:** every file shares one origin, the point where blade meets handle. Blades point +Y from it, handles hang -Y. Same position and rotation = assembled. The grip centre (hand position) is about 0.42 studs below the origin on every handle. A whole dagger is 2.3-2.7 studs long.

**Importing (Studio 3D Importer):** scale unit Stud; keep scene position and pivot at scene origin; blades and fittings get a Material (Metal) and Color, no texture; the grip gets one pattern PNG as TextureID or a SurfaceAppearance ColorMap.

**When M10 starts:** import the 23 meshes once into `ReplicatedFirst.Tools.Weapons` (or a `DaggerParts` folder), then a server-side generator picks blade + handle + pattern + colours, welds them at the shared origin, and attaches the result to the Royal Dagger tool's grip. The style stays Dagger; the randomization is cosmetic first, stats later if Bryan wants.
