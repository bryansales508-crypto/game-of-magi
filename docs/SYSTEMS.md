# SYSTEMS

_The full system map is written in Phase 2._

## Not synced

These scripts live inside models or asset folders that Rojo does not sync, so they stay only in the place file and are edited in Studio.

Only scripts that actually run and do something are listed. Left off: empty scripts, disabled scripts, notes-only scripts, and LocalScripts in Workspace, which never run there.

| Path | Class | What it does |
|---|---|---|
| `ReplicatedFirst.Objects.MissionWagon.Cradle.Seat.Script` | Script | Seat logic for the mission wagon (to be read in Phase 2) |
| `Workspace.Qarzin.ClothesStand.ClothingSpawn` | Script | Clothing and hat shop in Qarzin. Requires MarketHandler, ItemHandler, HeightHandler, AgeHandler and Assets. |
| `Workspace.NPC.DUMMY.NPCFetch` (×2) | Script | NPC AI. Uses NPController and DamageHandler. |
| `Workspace.NPC.DUMMY.Health` (×2) | Script | Health regen for the NPC dummies (stock Roblox script) |
| `Workspace.MAP.OCEAN.Folder.MovingPart.Waves` (×256) | Script | Ocean wave motion, one script per part |
| `Workspace.MAP.OCEAN.Folder.OceanWaves.Waves` (×255) | Script | Ocean wave motion, one script per part |
| `Workspace.MAP.OCEAN.Folder.OceanWaves.Decal.DecalWaves` (×255) | Script | Ocean decal animation, one script per part |

## Synced, but inside binary `.rbxm` files

These scripts sit inside GUI frames, which Rojo saves as binary `.rbxm` files. They are in `src/`, but they can't be read or edited as text there. Read and edit them in Studio.

| Script | File |
|---|---|
| `ServerScriptService.MISC.MissionHandler.SALEH.TextButton.Saleh` (LocalScript) | `src/ServerScriptService/MISC/MissionHandler/SALEH.rbxm` |
| `ServerScriptService.MISC.MissionHandler.AIN JAMALA.TextButton.AinJamala` (LocalScript) | `src/ServerScriptService/MISC/MissionHandler/AIN JAMALA.rbxm` |
| `ServerScriptService.MISC.MissionHandler.QARZIN.TextButton.Qarzin` (LocalScript) | `src/ServerScriptService/MISC/MissionHandler/QARZIN.rbxm` |
| `ServerScriptService.MISC.MissionHandler.SAHRAQIN.TextButton.Sahraqin` (LocalScript) | `src/ServerScriptService/MISC/MissionHandler/SAHRAQIN.rbxm` |
| `ServerScriptService.MISC.MissionHandler.ILLEGAL PORT.TextButton.IllegalPort` (LocalScript) | `src/ServerScriptService/MISC/MissionHandler/ILLEGAL PORT.rbxm` |
| `ServerScriptService.MISC.MissionHandler.RATHOLE.TextButton.Rathole` (LocalScript) | `src/ServerScriptService/MISC/MissionHandler/RATHOLE.rbxm` |
| `ServerScriptService.MISC.MissionHandler.JADDATYS HUT.TextButton.JaddatysHut` (LocalScript) | `src/ServerScriptService/MISC/MissionHandler/JADDATYS HUT.rbxm` |
| `ReplicatedFirst.GUI.Gender.Decisions` (Script) | `src/ReplicatedFirst/GUI/Gender.rbxm` |
| `ReplicatedFirst.GUI.UIGUI.MenuGUI.MasterFrame.MenuGUIFrame.MenuMechanics` (LocalScript) | `src/ReplicatedFirst/GUI/UIGUI/MenuGUI.rbxm` |
| `ReplicatedFirst.GUI.MissionGUI.DeliveryFrame.OutsideFrame.XButtonFrame.TextButton.LocalScript` (LocalScript) | `src/ReplicatedFirst/GUI/MissionGUI/DeliveryFrame.rbxm` |
