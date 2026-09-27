# Studio dump for Milestone 2 (read-only, 2026-09-27)

Cloud builders can't open `.rbxm` files. This is what's inside the GUIs and Studio-only scripts M2 replaces. Keep the LOOK (sizes, colours, fonts, images) exactly; only the scripts change.

## 1. `ReplicatedFirst.GUI.Gender` (the creation screen)

```
Gender (ScreenGui)
  Background (Frame)            Size {1,0},{1,0}; Pos {0.5,0},{0.5,0}; Anchor .5,.5; BG (117,87,27)
    Gender (Frame)              Size {0,250},{0,100}; Pos {0.5,0},{0.5,0}; Anchor .5,.5; BG (255,202,10)
      Feminine (TextButton)     Size {0,66},{0,54}; Pos {0.621,0},{0.155,0}; BG (189,91,21); Text "F"; TextColor white; Font Merriweather Bold; TextSize 42
      Masculine (TextButton)    Size {0,66},{0,54}; Pos {0.098,0},{0.175,0}; BG (84,126,189); Text "M"; same font
    ImageLabel (ImageLabel)     Size {0.5714,0},{0.3718,0}; Pos {0.5,0},{0.5,0}; Anchor .5,.5; Image rbxassetid://13473504106; ImageTransparency 0.35; ImageColor3 (229,151,62); ZIndex -1
    SkinColor (Frame)           Size {0,250},{0,75}; Pos {0.5,0},{0.6,0}; Anchor .5,.5; BG (255,202,10)
      BlackSkinBox (Frame)      Size {0,40},{0,40}; Pos {0.2,0},{0.15,0}; Anchor .5,0; BG (117,87,27)
        Button (TextButton)     Size {0.8,0},{0.8,0}; Pos {0.5,0},{0.5,0}; Anchor .5,.5; BG (75,54,36); Text ""; Font Balthazar Bold; TextSize 18
      BrownSkinBox (Frame)      Pos {0.5,0},{0.15,0}; Button BG (158,112,76)
      WhiteSkinBox (Frame)      Pos {0.8,0},{0.15,0}; Button BG (255,200,155)
    Enter (TextButton)          Size {0,100},{0,35}; Pos {0.5,0},{0.66,0}; Anchor .5,.5; BG (0,170,0); Text "ENTER"; Font Balthazar Bold; TextSize 22
  Decisions (Script)            <- Studio-only SERVER script, replaced by CreationController
```

`Decisions` behaviour to keep: Enter starts inactive (BackgroundTransparency 0.8, AutoButtonColor off) and becomes active (transparency 0) once both a gender and a skin are picked. Selected gender button darkens (Male -> (47,72,108), Female -> (117,56,13)); hover shows the same dark colour. Skin box shows "S" on the selected one, "S?" on hover over unselected. Enter writes Gender (1 male, 2 female) and SkinTone (1 Black, 2 Brown, 3 White), then destroys the GUI.

## 2. `ReplicatedFirst.GUI.UIGUI.MenuGUI` (the M menu card)

```
MenuGUI (ScreenGui)
  AppPressed (BoolValue)
  MasterFrame (Frame)           full screen, transparent
    MenuGUIFrame (Frame)        Size {0.18,0},{0.3905,0}; Pos {0.147,300},{0.5443,0}; Anchor .5,.5; transparent; ZIndex 5
      Outline (ImageLabel)      Size {1,0},{1.1,0}; Pos {0.4973,0},{0.4510,0}; Image rbxassetid://81599903982206
      BackgroundFill (ImageLabel) Size {1,0},{1.1,0}; Pos {0.499,0},{0.4481,0}; Image rbxassetid://99814341310974; ImageColor3 (144,127,86); ZIndex -1
      TitleBox (TextLabel)      Size {0,200},{0,25}; Pos {0.5,0},{0.1,0}; Text "THE MERCHANT'S CHILD"; black; Font Merriweather Regular Italic; TextSize 14
      NameBox (TextLabel)       Size {0,333},{0,37}; Pos {0.5,0},{0.15,0}; Text "AMIR"; TextColor3 (255,224,152); Font HighwayGothic Bold; TextSize 32
      StatBox (TextLabel)       Size {1,0},{0.05,0}; Pos {0.5,0},{0.24,0}; Text "MIDLANDER ❖ THE 20TH YEAR SINCE BIRTH ❖ 5'9"; black; Font Balthazar Bold; TextSize 12   <- clips (AUDIT P3): use TextScaled or a wider box
      BorderLine (Frame) x2     Size {0.8,0},{0.01,0}; Pos y 0.2 and 0.275; BG (66,58,39)
      Buttons (Frame)           Size {0.13,0},{0.1,0}; Pos {0.85,0},{0.375,0}
        App (ImageButton)       Image rbxassetid://109688233702728; ImageColor3 (121,106,72); hover (255,244,189); pressed (53,46,32)
        ImageButton x2          unused placeholders, same image, off-frame
      MenuMechanics (LocalScript) <- Studio-only, replaced by MenuController
      UIAspectRatioConstraint   AspectRatio 0.7977, FitWithinMaxSize, DominantAxis Width
```

Sibling frames cloned by the Apparel button, from `ReplicatedFirst.GUI.UIGUI`: `InventoryFrame`, `PlacementFrame`, `ViewCharaFrame`, `WordFrame`, `Tokens/*Token`. `InventoryFrame.InventoryBackdropSecondary.ScrollingFrame.StoneContainerApparel.Row1.PlacementPart<n>.StoneContainer` holds item tokens.

`MenuMechanics` live behaviour to keep (the drag code is commented out in the original and can be dropped):
- Waits for `player.Loaded`, then fills `NameBox` = upper(FirstName), `TitleBox` = "THE MERCHANT'S CHILD", `StatBox` = `<KINGDOM> ❖ THE <age>TH YEAR SINCE BIRTH ❖ <height>` where Kingdom 1/2/3 = MIDLANDER/EASTERNER/WESTERNER and height maps `Stats.Height` 0.725..1.450 in 0.025 steps to 4'5..7'0 (1.000 = 5'6). Re-runs on `Age.Changed`.
- Apparel button (`Buttons.App`): click toggles `AppPressed`; plays `ReplicatedFirst.SFX.UISounds.SelectSound1` on click and `SelectSound3` on hover (cloned to the Torso, destroyed on Ended); on open parents the four frames under `MasterFrame` and fills Row1 tokens from `OnCharacter.Inventory.Row1` (";"-split item codes, `assets.itemLookUp(code)` -> `<name>Token`); on close un-parents them.

## 3. VFX live in `ReplicatedFirst.VFX` (not ReplicatedStorage)

```
ReplicatedFirst.VFX
  HitEffects: Confusion, ParryCircle, Sparks1, Sparks2, Slashed1, Slashed2, HitParticle, BlockParticle, BlockBreakParticle (ParticleEmitters)
  RukhEffects: AttachmentInfo (StringValue), Rukh1-3, DepravityRukh1-3, SpecialRukh1-3, BorgOutline, BorgGlow, RukhInnerLightning, RukhOuterLightning, BorgShell, Piece1-4 (ParticleEmitters)
  StatusEffects: BleedDroplet1-2, BleedCut (Part with Decal)
  MiscEffects: DashTrail (Trail), SmallGroundBreak1-4, bashpart1-2, Cancel (Highlight), sparkle1-2, trueSparkle
```

## 4. `ReplicatedFirst.Assets` is a ModuleScript whose children are the Accessory models

Children: Imuchakk v2 (Type1-5), BlackKouCloak, RedKouCloak, MagiGemHolder1-5 (Parts), Boring Turban, Cowl, Fancy Turban, Feather, Head Cover, Mouth Head Cover, Short Covering, Side Headband, Super Torn Cloak, Short Wrap, Short Shoulder Cloak, Shoulder Cloak, Shoulder Cloth, Ripped Bandana, Proper Cloak, Low Bandana, Long Wrap, Long Scarf, Full Shoulder Cloak, Flamboyant Scarf, Fancy Shawl, Torn Cloak.

## 5. StarterGui

```
StarterGui
  HUD (ScreenGui)  [synced: src/StarterGui/HUD]
    BlockHandler (LocalScript), HealthHandler (LocalScript)
    HudFrame (Frame)
      BlockBarImageFrame: BlockHP (Frame, 1 child Frame), BlockBarImage (ImageLabel)
      HPBarImageFrame: HP (Frame: 1 TextLabel, 3 Frames), HPBarImage (ImageLabel)
      HungerBar: Padding (ImageLabel), UIListLayout
  Currency (ScreenGui, NOT synced): Bank.Icons.{Gold,Silver,Copper} (ImageLabels), Bank.CoinPurse.{Gold,Silver,Copper} (TextLabels)
  QuestLine (ScreenGui, NOT synced): Header.{Quest (TextLabel), Line}, Set (Frame: BUFFER, UIListLayout), ModFrame
  Announcer (ScreenGui, NOT synced): AnnouncerFrame (UIListLayout)
```

## 6. Missing from the place

- **No `AfterLife` model anywhere** (the old return-to-the-Rukh scene: `AfterlifeCamera`, `AfterlifeSpawnBlock`). The M2 death scene must build a simple stand-in from the old `WipeHandlerPart2` description (`docs/reference/old-game-scripts.txt` line 6503 on): golden neon body (223,193,112), clothes removed, head hidden and FalseHead neon, input frozen, scriptable camera, the character walking into the Rukh with `RukhEffects` particles.
- No `ImportantRemotes.Wipe` remote (only `Delivery`).
