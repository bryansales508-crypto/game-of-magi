--!strict
-- Dev tools: chat commands (the old `.field player value` style, kept) plus
-- the same commands over the DevCommand remote for the M1-05C dev panel.
-- Every command writes through DataService; nothing here touches a Value
-- directly.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local SaveSchema = require(ReplicatedStorage.Shared.SaveSchema)
local DataService = require(ServerScriptService.Server.Services.DataService)
local PlayerService = require(ServerScriptService.Server.Services.PlayerService)

local log = Log.new("DevService")

local NON_DEV_WARN_COOLDOWN = 60
local WATCH_PERIOD = 1

type CommandSpec = {
	help: string,
	run: (caller: Player, args: { string }) -> string,
}

local Commands: { [string]: CommandSpec } = {}

local DevService = {}

-- ==================== Age-change hooks (BUG-15) ====================
-- `.age`/`.age+` only changed the number; height, hair and max health
-- waited for the next birthday to catch up. AgeService and HealthService
-- each register a hook here instead of DevService requiring either back
-- (Roblox errors on a cyclic ModuleScript require, and both already
-- require DevService for Register/GetTimeScale).

-- Typed as variadic (not `()`) so pcall(hook, ...) below type-checks as
-- (boolean, ...any) instead of just (boolean); a real hook still isn't
-- expected to return anything meaningful (same trick Remotes.luau uses).
export type AgeChangeHook = (player: Player, data: SaveSchema.Data) -> ...any
local ageChangeHooks: { AgeChangeHook } = {}

function DevService.OnAgeChanged(hook: AgeChangeHook)
	table.insert(ageChangeHooks, hook)
end

local function runAgeChangeHooks(player: Player, data: SaveSchema.Data)
	for _, hook in ageChangeHooks do
		local ok, err = pcall(hook, player, data)
		if not ok then
			log:Error(string.format("an OnAgeChanged hook errored for %s: %s", player.Name, tostring(err)))
		end
	end
end

-- ==================== Permission ====================

-- The admin-list half of IsDev, pure and independent of Config.Debug.Enabled
-- (which is always true wherever SelfTestService runs, so it's the only
-- half of IsDev a self-test can actually exercise a rejection through).
function DevService.IsAdminUserId(userId: number): boolean
	for _, adminId in Config.Dev.Admins do
		if userId == adminId then
			return true
		end
	end
	return false
end

function DevService.IsDev(player: Player): boolean
	if Config.Debug.Enabled then
		return true
	end
	return DevService.IsAdminUserId(player.UserId)
end

local lastNonDevWarn: { [Player]: number } = {}

local function warnNonDev(player: Player)
	local now = os.clock()
	local last = lastNonDevWarn[player]
	if last and now - last < NON_DEV_WARN_COOLDOWN then
		return
	end
	lastNonDevWarn[player] = now
	log:Warn(string.format("%s tried a dev command without permission", player.Name))
end

-- ==================== Time scale ====================
-- Config is frozen, so a runtime-adjustable TimeScale lives here instead.
-- Later milestones (aging, day/night) should read DevService.GetTimeScale()
-- rather than Config.Debug.TimeScale once they need to speed up for tests.

local timeScale = Config.Debug.TimeScale
local timeScaleChangedBindable = Instance.new("BindableEvent")
DevService.TimeScaleChanged = timeScaleChangedBindable.Event :: RBXScriptSignal

function DevService.GetTimeScale(): number
	return timeScale
end

-- ==================== Mortality (BUG-20) ====================
-- Same reasoning as TimeScale: Config is frozen, so the runtime-adjustable
-- override lives here. Off by default in Studio (Config.Debug.DeathRolls)
-- so dev aging can't accidentally kill a test character; AgeService reads
-- this instead of the frozen Config value once it needs to roll a death.

local mortal = Config.Debug.DeathRolls

function DevService.IsMortal(): boolean
	return mortal
end

-- ==================== Tokenizer ====================
-- Splits on whitespace; a "double-quoted section" is kept as one token, so
-- multi-word city names and epithets don't need any other escaping.

local function tokenize(line: string): { string }
	local tokens: { string } = {}
	local i = 1
	local len = #line
	while i <= len do
		local c = line:sub(i, i)
		if c == " " or c == "\t" then
			i += 1
		elseif c == '"' then
			local closing = line:find('"', i + 1, true)
			if closing then
				table.insert(tokens, line:sub(i + 1, closing - 1))
				i = closing + 1
			else
				table.insert(tokens, line:sub(i + 1))
				i = len + 1
			end
		else
			local nextSpace = line:find("[ \t]", i)
			local stop = if nextSpace then nextSpace - 1 else len
			table.insert(tokens, line:sub(i, stop))
			i = stop + 1
		end
	end
	return tokens
end

-- ==================== Player resolution ====================

local function resolvePlayer(caller: Player, nameArg: string?): (Player?, string?)
	if nameArg == nil or nameArg == "" then
		return caller, nil
	end

	local needle = nameArg:lower()
	local candidates: { Player } = {}

	for _, player in Players:GetPlayers() do
		local name = player.Name:lower()
		local displayName = player.DisplayName:lower()
		if name == needle or displayName == needle then
			return player, nil
		end
		if name:sub(1, #needle) == needle or displayName:sub(1, #needle) == needle then
			table.insert(candidates, player)
		end
	end

	if #candidates == 1 then
		return candidates[1], nil
	end
	if #candidates == 0 then
		return nil, string.format("no player matching %q", nameArg)
	end

	local names: { string } = {}
	for _, player in candidates do
		table.insert(names, player.Name)
	end
	return nil, string.format("ambiguous player %q: %s", nameArg, table.concat(names, ", "))
end

-- Exposed so another service's own dev commands (registered via
-- DevService.Register below) can resolve a trailing player-name argument
-- the same way every built-in command does.
DevService.ResolvePlayer = resolvePlayer

-- Numeric commands (.coins, .age, .rukh, .bounty, .magoi) put an optional
-- player name in the LAST slot; since every value before it is a number,
-- a non-numeric trailing token is unambiguously the player name.
local function splitTrailingPlayer(args: { string }): ({ string }, string?)
	if #args == 0 then
		return args, nil
	end
	local last = args[#args]
	if tonumber(last) == nil then
		local rest = table.clone(args)
		table.remove(rest, #rest)
		return rest, last
	end
	return args, nil
end

-- ==================== Command registration ====================

local function register(name: string, help: string, run: (Player, { string }) -> string)
	Commands[name] = { help = help, run = run }
end

-- Exposed so another service can add its own dev commands (e.g. AgeService's
-- .birthday/.heart) without DevService having to require that service back
-- (Roblox errors on a cyclic ModuleScript require, and several services
-- already require DevService for GetTimeScale/permission checks).
function DevService.Register(name: string, help: string, run: (Player, { string }) -> string)
	register(name, help, run)
end

local function helpText(): string
	local names: { string } = {}
	for name in Commands do
		table.insert(names, name)
	end
	table.sort(names)

	local lines = { "Dev commands:" }
	for _, name in names do
		table.insert(lines, string.format(".%s - %s", name, (Commands[name] :: CommandSpec).help))
	end
	table.insert(lines, "Run on your own client (forwarded from chat): .region, .music, .lights")
	return table.concat(lines, "\n")
end

register("cmd", "lists every dev command", function(_caller, _args)
	return helpText()
end)

-- ==================== State snapshot ====================

local sessionStart: { [Player]: number } = {}

local SNAPSHOT_KEY_ORDER = {
	"name",
	"userId",
	"joinState",
	"age",
	"magoi",
	"rank",
	"goldRukh",
	"blackRukh",
	"epithet",
	"bounty",
	"copper",
	"silver",
	"gold",
	"walkSpeed",
	"health",
	"maxHealth",
	"position",
	"saveScope",
	"freshSave",
	"timeScale",
	"mortal",
	"livesLeft",
	"sessionSeconds",
}

local function buildSnapshot(target: Player): { [string]: any }
	local data = DataService.Get(target)
	local character = target.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local hrp = character and character:FindFirstChild("HumanoidRootPart")

	-- "n/a" (not {0,0,0}) when there's no character/HumanoidRootPart, so the
	-- overlay can tell "no character yet" apart from actually being at the
	-- map's origin (REVIEW-M1-05S #2).
	local position: any = "n/a"
	if hrp and hrp:IsA("BasePart") then
		local p = hrp.Position
		position = { x = p.X, y = p.Y, z = p.Z }
	end

	local started = sessionStart[target]

	return {
		name = target.Name,
		userId = target.UserId,
		joinState = PlayerService.GetState(target) or "n/a",
		age = if data then data.Age.Years else "n/a",
		magoi = if data then data.Progress.Magoi else "n/a",
		rank = "n/a", -- rank titles aren't built until M4 (#25)
		goldRukh = if data then data.Progress.GoldRukh else "n/a",
		blackRukh = if data then data.Progress.BlackRukh else "n/a",
		epithet = if data and data.Progress.Epithet ~= "" then data.Progress.Epithet else "n/a",
		bounty = if data then data.Bounty else "n/a",
		copper = if data then data.Economy.Copper else "n/a",
		silver = if data then data.Economy.Silver else "n/a",
		gold = if data then data.Economy.Gold else "n/a",
		walkSpeed = if humanoid then humanoid.WalkSpeed else "n/a",
		health = if humanoid then humanoid.Health else "n/a",
		maxHealth = if humanoid then humanoid.MaxHealth else "n/a",
		position = position,
		saveScope = Config.Debug.SaveScope,
		freshSave = Config.Debug.FreshSave,
		timeScale = DevService.GetTimeScale(),
		mortal = DevService.IsMortal(),
		-- M3B-05: Character.LivesLeft (this character's own remaining lives),
		-- not Meta.Lives (the incarnation count, still "n/a" here like rank).
		livesLeft = if data then data.Character.LivesLeft else "n/a",
		sessionSeconds = if started then math.floor(os.clock() - started) else "n/a",
	}
end

local function formatSnapshot(snapshot: { [string]: any }): string
	local lines: { string } = {}
	for _, key in SNAPSHOT_KEY_ORDER do
		local value = snapshot[key]
		if key == "position" and type(value) == "table" then
			local pos = value :: { x: number, y: number, z: number }
			table.insert(lines, string.format("  %s: (%.1f, %.1f, %.1f)", key, pos.x, pos.y, pos.z))
		else
			table.insert(lines, string.format("  %s: %s", key, tostring(value)))
		end
	end
	return table.concat(lines, "\n")
end

register("state", "[player] sends a state snapshot and logs it to Output", function(caller, args)
	local target, err = resolvePlayer(caller, args[1])
	if target == nil then
		return err or "player not found"
	end

	local snapshot = buildSnapshot(target)
	Remotes.Server.Fire("DevState", caller, snapshot)
	log:Info(string.format(".state %s:\n%s", target.Name, formatSnapshot(snapshot)))
	return string.format("State for %s sent", target.Name)
end)

-- ==================== Watch (live DevState stream) ====================

local watchers: { [Player]: boolean } = {}

register("watch", "on|off - stream DevState to you every second", function(caller, args)
	local mode = args[1] and args[1]:lower()
	if mode == "on" then
		watchers[caller] = true
		return "Watch on"
	elseif mode == "off" then
		watchers[caller] = nil
		return "Watch off"
	end
	return "usage: .watch on|off"
end)

-- ==================== Currency / stats ====================

local function currencyCommand(mode: "set" | "add"): (Player, { string }) -> string
	return function(caller, args)
		local rest, playerArg = splitTrailingPlayer(args)
		local copper = tonumber(rest[1])
		if copper == nil then
			return string.format("usage: .coins%s <copper> [silver] [gold] [player]", if mode == "add" then "+" else "")
		end
		local silver = tonumber(rest[2]) or 0
		local gold = tonumber(rest[3]) or 0

		local target, err = resolvePlayer(caller, playerArg)
		if target == nil then
			return err or "player not found"
		end
		local data = DataService.Get(target)
		if data == nil then
			return string.format("%s has no save loaded", target.Name)
		end

		local oldCopper, oldSilver, oldGold = data.Economy.Copper, data.Economy.Silver, data.Economy.Gold
		if mode == "add" then
			data.Economy.Copper += copper
			data.Economy.Silver += silver
			data.Economy.Gold += gold
		else
			data.Economy.Copper = copper
			data.Economy.Silver = silver
			data.Economy.Gold = gold
		end

		return string.format(
			"%s's coins: %d/%d/%d -> %d/%d/%d",
			target.Name,
			oldCopper,
			oldSilver,
			oldGold,
			data.Economy.Copper,
			data.Economy.Silver,
			data.Economy.Gold
		)
	end
end

register("coins", "<copper> [silver] [gold] [player] - set coins", currencyCommand("set"))
register("coins+", "<copper> [silver] [gold] [player] - add coins", currencyCommand("add"))

local function ageCommand(mode: "set" | "add"): (Player, { string }) -> string
	return function(caller, args)
		local rest, playerArg = splitTrailingPlayer(args)
		local years = tonumber(rest[1])
		if years == nil then
			return string.format("usage: .age%s <years> [player]", if mode == "add" then "+" else "")
		end
		local target, err = resolvePlayer(caller, playerArg)
		if target == nil then
			return err or "player not found"
		end
		local data = DataService.Get(target)
		if data == nil then
			return string.format("%s has no save loaded", target.Name)
		end

		local old = data.Age.Years
		data.Age.Years = if mode == "add" then old + years else years
		-- BUG-15: resize, grey hair and refresh max health right away
		-- instead of waiting for the next birthday.
		runAgeChangeHooks(target, data)

		return string.format("%s's age: %d -> %d", target.Name, old, data.Age.Years)
	end
end

register("age", "<years> [player] - set age", ageCommand("set"))
register("age+", "<n> [player] - add to age", ageCommand("add"))

local function magoiCommand(mode: "set" | "add"): (Player, { string }) -> string
	return function(caller, args)
		local rest, playerArg = splitTrailingPlayer(args)
		local n = tonumber(rest[1])
		if n == nil then
			return string.format("usage: .magoi%s <n> [player]", if mode == "add" then "+" else "")
		end
		local target, err = resolvePlayer(caller, playerArg)
		if target == nil then
			return err or "player not found"
		end
		local data = DataService.Get(target)
		if data == nil then
			return string.format("%s has no save loaded", target.Name)
		end

		local old = data.Progress.Magoi
		data.Progress.Magoi = if mode == "add" then old + n else n

		return string.format("%s's Magoi: %d -> %d", target.Name, old, data.Progress.Magoi)
	end
end

register("magoi", "<n> [player] - set Magoi", magoiCommand("set"))
register("magoi+", "<n> [player] - add to Magoi", magoiCommand("add"))

register("rukh", "<gold> <black> [player] - set both Rukh tallies", function(caller, args)
	local rest, playerArg = splitTrailingPlayer(args)
	local gold = tonumber(rest[1])
	local black = tonumber(rest[2])
	if gold == nil or black == nil then
		return "usage: .rukh <gold> <black> [player]"
	end
	local target, err = resolvePlayer(caller, playerArg)
	if target == nil then
		return err or "player not found"
	end
	local data = DataService.Get(target)
	if data == nil then
		return string.format("%s has no save loaded", target.Name)
	end

	local oldGold, oldBlack = data.Progress.GoldRukh, data.Progress.BlackRukh
	data.Progress.GoldRukh = gold
	data.Progress.BlackRukh = black

	return string.format("%s's Rukh: %d/%d -> %d/%d", target.Name, oldGold, oldBlack, gold, black)
end)

register("bounty", "<n> [player] - set bounty", function(caller, args)
	local rest, playerArg = splitTrailingPlayer(args)
	local n = tonumber(rest[1])
	if n == nil then
		return "usage: .bounty <n> [player]"
	end
	local target, err = resolvePlayer(caller, playerArg)
	if target == nil then
		return err or "player not found"
	end
	local data = DataService.Get(target)
	if data == nil then
		return string.format("%s has no save loaded", target.Name)
	end

	local old = data.Bounty
	data.Bounty = n

	return string.format("%s's bounty: %d -> %d", target.Name, old, n)
end)

-- Positional (not trailing-numeric-detected): quote a multi-word epithet so
-- it arrives as one token, e.g. .epithet "The Bold" PlayerName.
register("epithet", '<text> [player] - set epithet, quote multi-word text', function(caller, args)
	local text = args[1]
	if text == nil then
		return 'usage: .epithet <text> [player] (quote multi-word text)'
	end
	local target, err = resolvePlayer(caller, args[2])
	if target == nil then
		return err or "player not found"
	end
	local data = DataService.Get(target)
	if data == nil then
		return string.format("%s has no save loaded", target.Name)
	end

	local old = data.Progress.Epithet
	data.Progress.Epithet = text

	return string.format("%s's epithet: %q -> %q", target.Name, old, text)
end)

-- ==================== Teleport ====================

local function findSpawnPart(cityArg: string): (BasePart?, string?)
	local map = Workspace:FindFirstChild("MAP")
	local spawns = map and map:FindFirstChild("Spawns")
	if spawns == nil then
		return nil, "Workspace.MAP.Spawns not found"
	end

	local needle = cityArg:lower()
	for _, child in spawns:GetChildren() do
		if not child:IsA("BasePart") then
			continue
		end
		local name = child.Name:lower()
		if name == needle or name == needle .. "spawn" then
			return child, nil
		end
	end
	return nil, string.format("no spawn matching %q", cityArg)
end

-- Bryan (2026-10-03): `.tp saleh` must work for every city, built or not. A
-- city with no `Workspace.MAP.Spawns.<City>Spawn` part falls back to, in
-- order: its delivery part (`Workspace.MAP.MISSION.<City>Delivery`, or the
-- BUG-59 placeholder under `Workspace.MissionPlaceholders`), then its
-- `<City>REGION` part under `Workspace.Regions` (dropped to the ground below
-- its centre). Matching is case-insensitive on the city key.
local function findCityFallback(cityArg: string): (CFrame?, string?)
	local needle = cityArg:lower()

	local function matchesCity(name: string, suffix: string): boolean
		local lower = name:lower()
		return lower == needle .. suffix:lower()
	end

	local map = Workspace:FindFirstChild("MAP")
	local mission = map and map:FindFirstChild("MISSION")
	local placeholders = Workspace:FindFirstChild("MissionPlaceholders")
	for _, folder in { mission, placeholders } do
		if folder then
			for _, child in folder:GetChildren() do
				if child:IsA("BasePart") and (matchesCity(child.Name, "Delivery") or matchesCity(child.Name, "Delivery_PLACEHOLDER")) then
					return child.CFrame + Vector3.new(0, child.Size.Y / 2 + PlayerService.SPAWN_RAISE_STUDS, 0), child.Name
				end
			end
		end
	end

	local regions = Workspace:FindFirstChild("Regions")
	if regions then
		for _, part in regions:GetDescendants() do
			if part:IsA("BasePart") and matchesCity(part.Name, "REGION") then
				local params = RaycastParams.new()
				params.FilterType = Enum.RaycastFilterType.Exclude
				params.FilterDescendantsInstances = { part }
				local top = part.Position + Vector3.new(0, part.Size.Y / 2, 0)
				local hit = Workspace:Raycast(top, Vector3.new(0, -(part.Size.Y + 1000), 0), params)
				local position = if hit then hit.Position + Vector3.new(0, PlayerService.SPAWN_RAISE_STUDS, 0) else part.Position
				return CFrame.new(position), part.Name
			end
		end
	end

	return nil, nil
end

register("tp", "<city> - teleport your character to a spawn (or the city's drop-off / region when it has none)", function(caller, args)
	local cityArg = args[1]
	if cityArg == nil then
		return "usage: .tp <city>"
	end
	local character = caller.Character
	if character == nil then
		return string.format("%s has no character to teleport", caller.Name)
	end

	local spawnPart, err = findSpawnPart(cityArg)
	if spawnPart then
		character:PivotTo(spawnPart.CFrame + Vector3.new(0, spawnPart.Size.Y / 2 + PlayerService.SPAWN_RAISE_STUDS, 0))
		return string.format("Teleported %s to %s", caller.Name, spawnPart.Name)
	end

	local fallbackCFrame, fallbackName = findCityFallback(cityArg)
	if fallbackCFrame and fallbackName then
		character:PivotTo(fallbackCFrame)
		return string.format("Teleported %s to %s (no spawn part yet)", caller.Name, fallbackName)
	end
	return err or "spawn not found"
end)

register("cities", "lists known spawn points", function(_caller, _args)
	local map = Workspace:FindFirstChild("MAP")
	local spawns = map and map:FindFirstChild("Spawns")
	if spawns == nil then
		return "Workspace.MAP.Spawns not found"
	end

	local names: { string } = {}
	for _, child in spawns:GetChildren() do
		if child:IsA("BasePart") then
			table.insert(names, child.Name)
		end
	end
	table.sort(names)
	if #names == 0 then
		return "no spawns found"
	end
	return "Spawns: " .. table.concat(names, ", ")
end)

-- ==================== Time scale / save ====================

register("timescale", "<n> - set the runtime time scale (n > 0)", function(_caller, args)
	local n = tonumber(args[1])
	if n == nil or n <= 0 then
		return "usage: .timescale <n> (n > 0)"
	end
	local old = timeScale
	timeScale = n
	timeScaleChangedBindable:Fire(timeScale)
	return string.format("TimeScale: %s -> %s", tostring(old), tostring(timeScale))
end)

register("mortal", "on|off - toggle whether birthdays can roll a death (BUG-20)", function(_caller, args)
	local mode = args[1] and args[1]:lower()
	if mode == "on" then
		mortal = true
	elseif mode == "off" then
		mortal = false
	else
		return "usage: .mortal on|off"
	end
	return string.format("Mortal: %s", tostring(mortal))
end)

register("fresh", "[player] - wipe the save and reload the character", function(caller, args)
	local target, err = resolvePlayer(caller, args[1])
	if target == nil then
		return err or "player not found"
	end
	DataService.Wipe(target)
	target:LoadCharacter()
	return string.format("Fresh save for %s; character reloading", target.Name)
end)

register("save", "[player] - save now", function(caller, args)
	local target, err = resolvePlayer(caller, args[1])
	if target == nil then
		return err or "player not found"
	end
	DataService.Save(target)
	return string.format("Saved %s", target.Name)
end)

-- ==================== Dispatch ====================

-- Fires DevLocalCommand at the caller. A field so SelfTestService can swap
-- it (same stub trick as IsDev) without a real client.
function DevService.ForwardLocal(player: Player, text: string)
	Remotes.Server.Fire("DevLocalCommand", player, text)
end

-- The parse-and-run core, split out from Run so SelfTestService can call it
-- directly and check the reply text without a real remote or client on the
-- other end. Returns nil for "nothing to reply to": not a command line at
-- all, or a non-dev (who gets warnNonDev's side effect instead, and never a
-- reply, so a non-dev can't tell a real command from an unknown one).
function DevService.Dispatch(player: Player, line: string): string?
	local tokens = tokenize(line)
	if #tokens == 0 or tokens[1]:sub(1, 1) ~= "." then
		return nil
	end

	if not DevService.IsDev(player) then
		warnNonDev(player)
		return nil
	end

	local commandName = tokens[1]:sub(2):lower()
	local args = table.move(tokens, 2, #tokens, 1, {} :: { string })

	local spec = Commands[commandName]
	if spec == nil then
		-- BUG-47: not a server command, so hand it to the dev's own client
		-- (permission was checked above). The client replies for itself.
		DevService.ForwardLocal(player, string.sub(table.concat(tokens, " "), 2))
		return nil
	end

	local ok, result = pcall(spec.run, player, args)
	if ok then
		return result
	end

	log:Error(string.format("dev command .%s from %s errored: %s", commandName, player.Name, tostring(result)))
	return string.format("Error: %s", tostring(result))
end

-- Shared by Player.Chatted and the DevCommand remote.
function DevService.Run(player: Player, line: string)
	local reply = DevService.Dispatch(player, line)
	if reply == nil then
		return
	end
	Remotes.Server.Fire("DevReply", player, reply)
	log:Info(string.format("[dev %s] %s -> %s", player.Name, line, reply))
end

local function onPlayerAdded(player: Player)
	sessionStart[player] = os.clock()
	player.Chatted:Connect(function(message: string)
		DevService.Run(player, message)
	end)
end

local function onPlayerRemoving(player: Player)
	watchers[player] = nil
	sessionStart[player] = nil
	lastNonDevWarn[player] = nil
end

function DevService:Init()
	Remotes.Server.On("DevCommand", function(player: Player, line: string)
		DevService.Run(player, line)
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

function DevService:Start()
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	task.spawn(function()
		while true do
			task.wait(WATCH_PERIOD)
			for player in watchers do
				if player.Parent == Players then
					Remotes.Server.Fire("DevState", player, buildSnapshot(player))
				else
					watchers[player] = nil
				end
			end
		end
	end)
end

return DevService
