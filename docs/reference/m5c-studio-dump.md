# Studio dump for Phase 5C: the delivery board (read-only, 2026-09-29)

For the cloud builders. The lore text, pay preview and per-city panel logic are in code you can read: `src/ReplicatedStorage/Modules/MissionDeliniation.luau` (the city descriptions such as "Saleh is a small desert village..." live there) and `src/ServerScriptService/MISC/MissionHandler/init.server.luau` (the trade-route table at line 26, modifier rolls, the package, the Touched drop zones, a courier Highlight at line 316 with `DepthMode = AlwaysOnTop`, which is the old beacon). What follows is only what lives in the place or in binary files.

## 1. The seven city buttons (inside `MissionHandler.rbxm`, copied into the player's board at runtime)

Each is `Frame > TextButton > LocalScript`, no lore. Frame: `AnchorPoint 0.5,0.5`, `Size {0.9,0},{1,0}`, per-city `BackgroundColor3`. TextButton: `Size {0.9,0},{0.7,0}`, Font Merriweather Bold, TextSize 18, black border (Rathole's border matches its fill).

| Instance | Text | BackgroundColor3 (0-1) | LocalScript key |
|---|---|---|---|
| SALEH | "SALEH" | 0.333, 0.667, 0.498 | "Saleh" |
| AIN JAMALA | "AIN JAMALA" | 0.251, 0.145, 0.282 | "AinJamala" |
| QARZIN | "QARZIN" | 0.749, 0.518, 0.286 | "Qarzin" |
| SAHRAQIN | "SAHRAQIN" | 0.490, 0.655, 0.855 | "Sahraqin" |
| ILLEGAL PORT | "ILLEGAL PORT" | 0, 0, 0 | "IllegalPort" |
| RATHOLE | "RATHOLE" | 0.392, 0.333, 0.459 | "Rathole" |
| JADDATYS HUT | "JADDATY'S HUT" | 0.671, 0.678, 0.251 | "JaddatysHut" |

Each LocalScript is one line: `require(ReplicatedStorage.Modules.MissionDeliniation).DeliveryProtocol(player, button, "<key>")`. In 5C the buttons are recreated in code from `Shared/Data/Cities.luau` (same text, colours, font) and the rbxm frames become art only (moved under `ReplicatedFirst/GUI/MissionGUI/Cities/`), or dropped if the client builds them from data; the lead accepts either.

## 2. `ReplicatedFirst.GUI.MissionGUI` (synced rbxm assets; keep the look)

```
DeliveryFrame (ScreenGui, IgnoreGuiInset)
  OutsideFrame (Frame)            Size {0,700},{0,452}; Pos {0.5,0},{0.5,0}; Anchor .5,.5; BG (0.875,0.812,0.341) transparency 0.8
    Frame (Frame)
      DescriptionFrame (Frame)    Size {0,392},{0,397}; Pos {0.69,0},{0.5,0}; Anchor .5,.5; BG (0.373,0.322,0.141)
        TextContainer (Frame)     Size {0,370},{0,373}; Pos {0.026,0},{0.025,0}; BG (0.529,0.459,0.200) transparency 0.35; Visible=false until a city is picked
          PayRow (Frame)          Size {0.75,0},{0.095,0}; Pos {0.5,0},{0.875,0}; Anchor .5,.5; transparent; UIListLayout
            StartButton (TextButton)  "START"; Size {0.45,0},{1,0}; Merriweather Bold 18; white on (0,0.659,0)
            Frame (divider), Money (TextLabel: Balthazar Bold 18, white; the pay number), Piece (ImageLabel rbxassetid://119315569242622, 18x18: the coin icon), Frame (divider)
          CityPic (ImageLabel)    rbxassetid://80085994447501; Size {0.8,0},{0.45,0}; Pos {0.5,0},{0.25,0}; Anchor .5,.5 (the code swaps the image per city)
          CityDesc (TextLabel)    Balthazar Italic 14, white, left/top aligned; Size {0.9,0},{0.237,0}; Pos {0.5,0},{0.644,0} (the lore paragraph)
        Frame x2 (thin divider lines, BG (0.671,0.643,0.490), Visible=false)
      ScrollingFrame              Size {0,235},{0,397}; Pos {0.2,0},{0.5,0}; Anchor .5,.5; CanvasSize {0,0},{2,0}; BG (0.373,0.322,0.141); UIListLayout; Spacer 10x10; Slot1..Slot4 (Frames 225x56, transparent, empty: the city buttons go here)
    XButtonFrame (Frame)          Size {0,36},{0,37}; Pos {1.05,0},{0.05,0}; BG (0.875,0.812,0.341)
      ImageLabel (rbxassetid://16802675313, ImageColor3 0.71 grey), TextButton (invisible click-catcher) > LocalScript: fires the OLD `ImportantRemotes.Delivery:FireServer("Exit")` (replace in 5C)
QuestTracker (BillboardGui)       Size {1000,0},{1000,0}; AlwaysOnTop; MaxDistance 9999
  Frame > Rukh (ImageLabel rbxassetid://136246658976548, Size {1,0},{0,50}, ImageColor3 (1,1,0.498)), Distance (TextLabel "0m", Merriweather Bold 30, white), UIListLayout
QuestLineBox (Frame)              Size {1,0},{0.075,0}; BG (0.314,0.298,0.200) transparency 0.8; UICorner
  Distance (TextLabel "0m", Merriweather Bold 20, right-aligned), Quest (TextLabel "DELIVERY", Balthazar 24, (0.741,0.655,0.443)), MODROW (Frame + UIListLayout: the modifier icons row)
MODCONTAINER (Frame)              Size {0.25,0},{1,0}; Pos {0.6,0},{0.5,0}
  BONUS (TextButton "!!!", red (0.792,0.129,0.129), Balthazar 24, transparent, UICorner)   <- the modifier view button
Frame (spacer)
ModChance (TextLabel "!!!", (0.757,0,0), Balthazar Italic 22) > Percentage (TextLabel "25%", Balthazar Bold 14)
ModPopOut (Frame)                 Size {1,0},{0.15,0}; Pos {0.77,0},{0.55,0}; BG (0.314,0.298,0.200) transparency 0.8; UICorner
  ModType (TextLabel "Time Crunch", Balthazar 24, (0.659,0.145,0.125)), Constraint (TextLabel "Failed.", Balthazar 16, white; Pos {0.5,0},{0.594,0})
```

## 3. Drop zones: `Workspace.MAP.MISSION` (bare anchored Parts 4x6x5, grey, CanCollide, no children; the old script uses Touched)

| Part | Position |
|---|---|
| QarzinDelivery | 1761.86, 199.22, -7571.19 |
| SalehDelivery | -2459.5, 197.41, -8458.78 |
| RatholeDelivery | -5064, 97.05, -6700.53 |
| JaddatysHutDelivery | -6364.55, 197.41, -8423.13 |
| IllegalPortDelivery | -159.21, 295.15, -5313.41 |
| SahraqinDelivery | 7400.8, 186.67, -7302 |
| AinJamalaDelivery | 3779.3, 197.41, -8866.13 |

Only Qarzin is a built city; the others are markers (Bryan). The board opens by interacting with the `<City>Delivery` part.

## 4. `StarterGui.QuestLine` and `StarterGui.Announcer` (NOT synced; filled at runtime)

```
QuestLine (ScreenGui)
  Header (Frame, Size {0.15,0},{0.075,0}, Pos {0.917,0},{0.45,0}, Anchor .5,.5): Quest (TextLabel "QUEST", Balthazar 42, gold (1,0.878,0.592)), Line (ImageLabel rbxassetid://119040853264737, gold)
  Set (Frame, Size {0.15,0},{0.5,0}, Pos {0.917,0},{0.7,0}): BUFFER spacer + UIListLayout   <- quest entries go here
  ModFrame (Frame, Size {0.1,0},{0.5,0}, Pos {0.775,0},{0.74,0}): UIListLayout          <- modifier pop-outs go here
Announcer (ScreenGui): AnnouncerFrame (Frame, Size {0.25,0},{0.1,0}, Pos {0.5,0},{0.1,0}): UIListLayout
```
