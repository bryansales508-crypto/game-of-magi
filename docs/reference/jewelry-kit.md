# Jewelry kit (shelved asset, Bryan 2026-10-03)

**Where:** `assets/jewelry-kit-roblox-r6.zip` (1.75 MB). Bryan had the models generated for a later project (wearable jewelry on the R6 body). **Shelved**: nothing uses it yet; the natural home is the clothes shop / gear work (M10 Weapons and gear, or the Bank milestone's spending sinks).

**What's inside** (from the kit's README and `pieces.csv`):
- 36 pieces by body part: `head/` (circlet, turban jewel, coin veil, hilal/coin/bell/fan earrings as pairs, ear-cuff chain, hair comb), `torso/` (coin collar, hirz amulet case, bib collar, gem choker, body chain, pectoral plate, shoulder chains, coin bandolier, cloak clasp, star medallion, coin belt, khanjar belt), `right_arm/` + `left_arm/` (bangle stack, engraved cuff, serpent armlet, bead bracelet, gem/signet/hilal rings - mirrored pairs), `right_leg/` + `left_leg/` (anklets etc.).
- 8 pieces have a charm slot; variants with the charm attached end in `__Hilal`, `__Coin`, `__Teardrop`, `__Star`, `__Khamsa`, `__Eye`, `__Bell`, `__Tassel`. `charms/` has the 8 charms alone (origin = hang point) and `slots.csv` says where each hangs on each piece. 92 shapes before colours.
- Each file has a `..._Metal` mesh and, if it has stones, a `..._Gems` mesh (own Color, or Neon to glow). `engraving/` holds 4 grayscale tiling patterns for the metal (TextureID or SurfaceAppearance ColorMap; the part's Color tints them).

**The one placement rule:** every file's origin is the CENTRE of its R6 body part. Put the piece at the body part's position and rotation and it's in place; scaling it with the body part (taller/older characters) keeps it seated. Files face +Z, up +Y, right arm at -X; if a piece imports backwards, rotate 180 degrees about Y. Everything is rigid. Rings sit half-sunk into the arm's outside face near the bottom (R6 has no fingers).

**Importing (Studio 3D Importer):** scale unit Stud; keep pivots at the scene origin (the body-part centre); Metal gets a Material and Color, Gems their own Color.

**When it comes back:** import once into a `ReplicatedFirst.Objects.Jewelry` folder; a server-side `Wear` path welds a piece to its body part at the part's CFrame (same approach as hats in ItemService), with colour/engraving/charm as the randomizable bits; HeightHandler's body scaling already scales welded accessories, which is why the centre-origin rule matters.
