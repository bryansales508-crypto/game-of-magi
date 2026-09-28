# Studio dump for Phase 5B: the Qarzin clothes stand (read-only, 2026-09-29)

For the cloud builders (they can't see the place). Keep the art and the behaviour; only the code moves into `ShopService`.

## 1. `Workspace.Qarzin.ClothesStand` (Folder), the parts the script uses

```
ClothesStand (Folder)
  ClothingSpawn (Script)              <- Studio-only, replaced by ShopService (disabled at startup until Bryan deletes it)
  HatTable (Folder)
    HeadHolder (Part) x8              invisible 1x1x1 anchors; a hat MeshPart clone is placed at each; a ProximityPrompt is parented to the holder
  OutfitTable (Folder)
    ClothingRack (Model) x9           stock R6 dummy rigs: Body Colors, Shirt, Pants, Humanoid, Torso/limbs/HumanoidRootPart, Animate (stock), plus
      ShirtHL (Part)                  hover/click spot for the shirt (ClickDetector + ProximityPrompt at runtime; has a Highlight child in the rig)
      PantsHL (Part)                  hover/click spot for the pants
  StandTable (Folder)
    CloakHolder (Part) x3             invisible anchors; a cloak MeshPart clone at each; prompt on the holder
  (unused by the script: ClothesRacker, Build, Table1/2, Stand1-3, Present1-4, JewelryTable/JewelryHolder x4)
```

No ProximityPrompt or ClickDetector exists statically; the script creates them. Positions are in the place; the code only needs the names.

## 2. The old script, verbatim (`Workspace.Qarzin.ClothesStand.ClothingSpawn`)

Behaviour to port exactly (colour name "Gold" becomes "Tan", same RGB):
- Requires the OLD `Character.HeightHandler`, `MISC.MarketHandler` (prices), `ReplicatedFirst.Assets`, `Character.AgeHandler`, `Character.ItemHandler`.
- `SHOP_COLORS`: Standard pool = White (255,255,255) w80; Gold->Tan (230,210,129) w25, PriceMult 1.25; Black (35,35,35) w10, PriceMult 1.5. Variety pool (shirts only) = Red (175,42,42), Blue (131,170,255), Green (80,198,71), Yellow (255,204,0), Purple (170,85,255), Orange (255,85,0), Pink (255,126,199), Brown (131,82,39), Turquoise (54,216,183), Black (53,53,53), White (199,199,199), all w10. `rollShopColor(pool)` is a weighted roll.
- `task.wait(5)` then stock once per server:
  - Hats: `randomAmount = random(#holders/3, #holders)` of the 8 `assets.hats.head` names, no duplicates; clone `ReplicatedFirst.Assets[<name>].MeshPart`, anchored at the holder CFrame, coloured with a Standard roll; rotation fixes: "Short Covering"/"Cowl" rotate 180 about Y; "Feather" `CFrame.Angles(rad(-25), rad(45), rad(90)) * CFrame.new(-0.25,0,0)`; prompt HoldDuration 2, ObjectText = hat name, key E; `econCall(prompt, name, colour, "H")`.
  - Outfits: shirts = `assets.outfits.desertBasic.shirt` minus index 9 ("Short Sleeve Rags", starter rags); pants = `desertBasic.pants` minus index 2 and 3 (the rag pants), so only "Standard" is for sale; `randomAmount2 = random(#racks/3, #racks)` capped at #shirts; pick an EMPTY rack at random (PantsTemplate == ""), make its parts visible (Transparency 0 except HumanoidRootPart and *HL parts) and CollisionGroup "Default"; ShirtTemplate = shirt id with a Variety colour; PantsTemplate = pants id with a Standard colour; on ShirtHL and PantsHL: a ClickDetector (MaxActivationDistance 10) whose hover sets the HL part Transparency 0.999, enables its `Highlight` child and enables the prompt (leave: transparency 1, highlight off, prompt off); a ProximityPrompt HoldDuration 2, ClickablePrompt, RequiresLineOfSight false, Enabled false, ObjectText "<Colour> <shirt name>" / "<Colour> Harem Pants"; `econCall(..., "S")` / `(..., "P")`; the shirt is removed from the pool, pants are reused.
  - Cloaks: every one of the 3 holders gets a random distinct cloak from `assets.cloaks` (14 names): clone its MeshPart, anchored, `Holder.CFrame * CFrame.new(0,-1.5,0) * CFrame.Angles(0, rad(180), 0)`, Standard colour, plus per-cloak offsets: Super Torn Cloak (-0.8,-0.3,0.25); Torn Cloak (0.1,-0.5,0.5); Long Wrap (0,0.35,0); Flamboyant Scarf (0,-0.2,0.9) then rotate 180 about Y; Proper Cloak (0,1,0.05); Shoulder Cloak (0,-0.534,0); Ripped Bandana (0,.275,0); Low Bandana (0,1,0); Long Scarf (0,.325,.2); Full Shoulder Cloak (0.55,0,0.2); Fancy Shawl (0,0.5,0.1); Short Wrap (0,1.15,0.1) then rotate 90 about Y; Shoulder Cloth (1.5,1.2,0); Short Shoulder Cloak (-1.5,1,0); prompt as for hats; `econCall(..., "C")`.
- `econCall(prompt, itemName, colour, type)`: `price, coin = market.GetPrice(city, "Clothing", colour, type)`; `prompt.ActionText = price .. " " .. coin`; on Triggered: `code = ItemHandler.encode(type, itemName, ItemHandler.colorToCode(colour.color))`; `market.GetPlayerEcon(player, price, coin, code) == "yes"` then `ItemHandler.equip(code, character)` and write the code into `OnCharacter.Clothes.Clothing_Shirt` / `Clothing_Pants` / the first empty `OnCharacter.Hats` slot.

## 3. Asset tables (`ReplicatedFirst.Assets`, verbatim)

```lua
module.hats = { head = { "Feather", "Cowl", "Fancy Turban", "Boring Turban", "Head Cover", "Mouth Head Cover", "Short Covering", "Side Headband" } }
module.cloaks = { "Fancy Shawl", "Flamboyant Scarf", "Full Shoulder Cloak", "Long Scarf", "Long Wrap", "Low Bandana", "Proper Cloak", "Ripped Bandana", "Short Shoulder Cloak", "Short Wrap", "Shoulder Cloak", "Shoulder Cloth", "Super Torn Cloak", "Torn Cloak" }
module.outfits = { desertBasic = {
  shirt = { {id="rbxassetid://73902351418182", name="Long Sleeve"}, {id="rbxassetid://78386065209239", name="Vest"}, {id="rbxassetid://126057009576010", name="Short Sleeve"}, {id="rbxassetid://75749185367229", name="Croptop"}, {id="rbxassetid://83154660188892", name="Fist Wrapping"}, {id="rbxassetid://113331770157087", name="Arm Wrapping"}, {id="rbxassetid://118777215103181", name="Left Arm Wrapping"}, {id="rbxassetid://105315663149351", name="Right Arm Wrapping"}, {id="rbxassetid://15091718013", name="Short Sleeve Rags"} },
  pants = { {id="rbxassetid://103174839005173", name="Standard"}, {id="rbxassetid://15091719460", name="Shoes and Rags"}, {id="rbxassetid://75087301812346", name="Barefooted and Rags"} } } }
```

## 4. Notes
- The rag shirt and the two rag pants are starter clothes, kept out of the shop on purpose (Bryan: one pants design for sale today; the pants pool in the new data must take more later).
- The old highlight was server-side and visible to everyone; 5B makes it client-only.
- Prices came from `MarketHandler.GetPrice` on main (`src/ServerScriptService/MISC/MarketHandler.luau`); read it for the base numbers per type and the colour multipliers, then express them as base copper prices in `Shared/Data/Shop.luau` shown through the 5A band rule.
