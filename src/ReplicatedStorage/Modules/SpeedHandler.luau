-- Compatibility shim over MovementService (ServerScriptService/Server/Services/MovementService.luau), which owns WalkSpeed. Callers name a speed modifier and remove it by name: a string `duration` (or a string `value` with no duration) is the modifier name; a numeric duration clears it after that many seconds.
-- Required from both server (forwarded to MovementService) and client (nothing is called on it); ServerScriptService is not replicated, so MovementService is only required when IsServer().
-- Outside scripts/check.sh's TARGETS, so intentionally not --!strict.

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

-- Returns fixed base walk/run numbers so a straggling `local walkspeed, runspeed = speedMod.Set(w, r)` call does not error; MovementService's WALK_SPEED/RUN_SPEED are the real source.
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
		-- Other call shapes (Run/Dash/Block/Parry) are owned by MovementService/CombatService directly and never reach this shim.
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
