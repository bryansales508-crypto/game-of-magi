-- Compatibility shim (M3-02, TRIAGE #9 approved removal). The real
-- SpeedHandler/InteractionsDesign speed system is gone; MovementService
-- (ServerScriptService/Server/Services/MovementService.luau) owns WalkSpeed
-- now. One real caller is left until a later milestone deletes it too:
-- EffectsService.server.luau's TrueStun freeze (kept until M3-06). It just
-- wants "name a modifier, remove a modifier by name" - decoded from how it
-- actually calls this module (the `duration` argument, when it's a string
-- rather than a number of seconds, was always the removable tag the old
-- code later matched in SpeedHandleRemove, whatever its literal
-- Instance.Name/Value bookkeeping did under the hood). MissionHandler's own
-- heavy-cargo slow used to be the other caller; M5C-01 replaced it with
-- MissionService calling MovementService.SetModifier directly, and deleted
-- MissionHandler.
--
-- This module is required from both the server (real work, forwarded to
-- MovementService) and the client (PhysicalHandler.client.luau requires it
-- but never calls anything on it - AUDIT D2, dead code): ServerScriptService
-- isn't replicated, so MovementService is only required when IsServer().
--
-- Not part of the new (checked) code - see scripts/check.sh's TARGETS - so
-- this intentionally isn't --!strict, matching every other legacy module
-- it sits alongside.

local RunService = game:GetService("RunService")

local module = {}

local MovementService = nil
if RunService:IsServer() then
	local ok, result = pcall(function()
		return require(game.ServerScriptService.Server.Services.MovementService)
	end)
	if ok then
		MovementService = result
	end
end

-- Old callers used this for the base walk/run numbers before applying
-- their own multipliers; MovementService's own WALK_SPEED/RUN_SPEED
-- constants are the one source of truth for those now. Kept only so a
-- straggling `local walkspeed, runspeed = speedMod.Set(w, r)` call doesn't
-- error; nothing still uses the numbers it returns for anything real.
function module.Set(_walkspeed, _runspeed)
	return 16, 28
end

function module.SpeedHandle(chara, value, duration)
	if MovementService == nil or chara == nil then
		return
	end

	local name, mult
	if type(duration) == "string" then
		name = duration
		mult = if type(value) == "number" then value else 1
	elseif type(value) == "string" and duration == nil then
		name = value
		mult = 1
	else
		-- Old Run/Dash/Block/Parry call shapes: those systems are owned by
		-- MovementService/CombatService directly now (M3-02/M3-03), never
		-- reached through this shim in the new code.
		return
	end

	MovementService.SetModifier(chara, name, mult)
	if type(duration) == "number" then
		task.delay(duration, function()
			MovementService.ClearModifier(chara, name)
		end)
	end
end

function module.SpeedHandleRemove(chara, val)
	if MovementService == nil or chara == nil or type(val) ~= "string" then
		return
	end
	MovementService.ClearModifier(chara, val)
end

return module
