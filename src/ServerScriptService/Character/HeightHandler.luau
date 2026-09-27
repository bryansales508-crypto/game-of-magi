-- BUG-11: compatibility shim. HeightHandler moved to
-- Server/Services/AgeService/HeightHandler.luau in M2-02; ItemHandler.luau
-- and MissionHandler were repointed to the new path there, but the
-- Studio-only Workspace.Qarzin.ClothesStand.ClothingSpawn script (a live
-- place script, not synced into src/) still requires this old path
-- directly and can't be repointed from here. Delete this shim once M5
-- rebuilds the clothes shop and that script is gone.
return require(game.ServerScriptService.Server.Services.AgeService.HeightHandler)
