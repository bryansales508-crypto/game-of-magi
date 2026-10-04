--!strict
-- The join pipeline: load -> character ready -> spawn -> ready, in order, with no one-time
-- signal that can be missed.
-- State lives in one Player attribute, `JoinState`: "Loading" -> "Loaded" -> "Ready", reset to
-- "Loading" on every respawn. Anything can read or watch it.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local DataService = require(ServerScriptService.Server.Services.DataService)

local log = Log.new("PlayerService")

export type JoinState = "Loading" | "Loaded" | "Ready"
export type JoinEvent = "Respawn" | "CharacterPlaced" | "ClientReady"

local HRP_TIMEOUT = 10
local SPAWN_WAIT_TIMEOUT = 10
local SPAWN_RAISE_STUDS = 3
local STUCK_LOADING_SECONDS = 120

local readyBindable = Instance.new("BindableEvent")

-- The character JoinState == "Ready" refers to. CharacterAdded/CharacterRemoving order isn't
-- guaranteed across scripts, so IsReady checks this generation too, or a reader could see the
-- previous life's "Ready" for a frame.
local readyCharacter: { [Player]: Model } = {}

local PlayerService = {}
PlayerService.Ready = readyBindable.Event :: RBXScriptSignal
-- Shared with DevService's .tp so both place characters at a spawn with the same margin.
PlayerService.SPAWN_RAISE_STUDS = SPAWN_RAISE_STUDS

-- Pure, so SelfTestService can exercise every transition. The only place the state machine's
-- rules live; setState applies the result.
function PlayerService.NextJoinState(state: JoinState, event: JoinEvent): JoinState
	if event == "Respawn" then
		return "Loading"
	elseif event == "CharacterPlaced" then
		if state == "Loading" then
			return "Loaded"
		end
		return state
	elseif event == "ClientReady" then
		if state == "Loaded" then
			return "Ready"
		end
		return state
	end
	return state
end

function PlayerService.GetState(player: Player): JoinState?
	local value = player:GetAttribute("JoinState")
	if value == "Loading" or value == "Loaded" or value == "Ready" then
		return value
	end
	return nil
end

function PlayerService.IsReady(player: Player): boolean
	return PlayerService.GetState(player) == "Ready" and readyCharacter[player] == player.Character
end

-- Applies one event to JoinState and writes the attribute (a Respawn is written even if already
-- "Loading": it is the reset signal).
local function setState(player: Player, event: JoinEvent): JoinState
	local current: JoinState = PlayerService.GetState(player) or "Loading"
	local nextState: JoinState = PlayerService.NextJoinState(current, event)
	if nextState ~= current or event == "Respawn" then
		player:SetAttribute("JoinState", nextState)
	end
	return nextState
end

-- Waits for JoinState == "Ready" and returns the character it became ready with (nil on timeout
-- or if the player leaves). Re-checks player.Parent each iteration so no thread leaks.
function PlayerService.WaitForReady(player: Player, timeout: number?): Model?
	local deadline = if timeout then os.clock() + timeout else nil
	while not (PlayerService.IsReady(player) and player.Character) do
		if player.Parent ~= Players then
			return nil
		end
		if deadline and os.clock() >= deadline then
			return nil
		end
		task.wait()
	end
	return player.Character
end

-- Resolves Workspace.MAP.Spawns.QarzinSpawn fresh each call, with a bounded wait and a logged
-- error instead of hanging if the map isn't there.
local function getSpawnCFrame(): CFrame?
	local map = Workspace:WaitForChild("MAP", SPAWN_WAIT_TIMEOUT)
	if map == nil then
		log:Error("Workspace.MAP not found; can't place characters at spawn")
		return nil
	end

	local spawns = map:WaitForChild("Spawns", SPAWN_WAIT_TIMEOUT)
	if spawns == nil then
		log:Error("Workspace.MAP.Spawns not found; can't place characters at spawn")
		return nil
	end

	local qarzin = spawns:WaitForChild("QarzinSpawn", SPAWN_WAIT_TIMEOUT)
	if qarzin == nil or not qarzin:IsA("BasePart") then
		log:Error("Workspace.MAP.Spawns.QarzinSpawn is missing or not a Part; can't place characters at spawn")
		return nil
	end

	-- `+ Vector3` (not CFrame.new(position)) keeps the spawn part's facing. Raised by half the
	-- part's height plus a margin so a tall spawn part still clears the character.
	return qarzin.CFrame + Vector3.new(0, qarzin.Size.Y / 2 + SPAWN_RAISE_STUDS, 0)
end

-- Where a player should appear instead of the city spawn (the jail cell while serving a sentence), or nil. One provider; JailService sets it.
local spawnOverride: ((player: Player) -> CFrame?)? = nil

function PlayerService.SetSpawnOverride(provider: (player: Player) -> CFrame?)
	spawnOverride = provider
end

-- The city spawn point (QarzinSpawn), or nil if the map is missing. May yield briefly.
function PlayerService.GetSpawnCFrame(): CFrame?
	return getSpawnCFrame()
end

-- Logs once (never kicks) if this exact character is still "Loading" after
-- STUCK_LOADING_SECONDS. Stale (silent) if player.Character has moved on.
local function startStuckWatchdog(player: Player, character: Model)
	task.spawn(function()
		task.wait(STUCK_LOADING_SECONDS)
		if player.Parent ~= Players or player.Character ~= character then
			return
		end
		if PlayerService.GetState(player) == "Loading" then
			log:Warn(string.format("%s has been stuck in Loading for %d seconds", player.Name, STUCK_LOADING_SECONDS))
		end
	end)
end

local function onCharacterAdded(player: Player, character: Model)
	setState(player, "Respawn")
	startStuckWatchdog(player, character)

	local hrp = character:WaitForChild("HumanoidRootPart", HRP_TIMEOUT)
	if player.Parent ~= Players or player.Character ~= character then
		return
	end

	if hrp == nil then
		log:Error(string.format("%s's character has no HumanoidRootPart after %ds; not placing at spawn", player.Name, HRP_TIMEOUT))
	else
		local spawnCFrame = getSpawnCFrame()
		if spawnCFrame then
			character:PivotTo(spawnCFrame)
		end
	end

	-- Usually already loaded; this only waits when a fast auto-spawn races PlayerAdded's load.
	local data = DataService.WaitFor(player)
	if data == nil or player.Parent ~= Players or player.Character ~= character then
		return
	end

	-- Needs the save, so it runs after the default placement above.
	local override: CFrame? = nil
	if spawnOverride then
		local okOverride, result = pcall(spawnOverride, player)
		if okOverride then
			override = result
		else
			log:Warn(string.format("Spawn override failed for %s: %s", player.Name, tostring(result)))
		end
	end
	if override and hrp then
		character:PivotTo(override)
	end

	setState(player, "CharacterPlaced")
end

local function onPlayerAdded(player: Player)
	if PlayerService.GetState(player) ~= nil then
		-- Start() and PlayerAdded can both reach a just-joined player; run the pipeline once.
		return
	end

	player:SetAttribute("JoinState", "Loading")
	player.CharacterAdded:Connect(function(character: Model)
		onCharacterAdded(player, character)
	end)
	-- Fires before the next CharacterAdded: resets state immediately so nothing reads a stale
	-- "Ready"/"Loaded".
	player.CharacterRemoving:Connect(function()
		readyCharacter[player] = nil
		setState(player, "Respawn")
	end)

	-- A character can already exist here (Start()'s catch-up loop reaches a player who
	-- auto-spawned before Init connected CharacterAdded); without this that join stays
	-- "Loading" forever.
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

function PlayerService:Init()
	Remotes.Server.On("ClientReady", function(player: Player)
		if PlayerService.GetState(player) ~= "Loaded" then
			return
		end
		local character = player.Character
		if character == nil then
			-- Rare race: the character was removed between Loaded and this
			-- call. Stay Loaded; the next CharacterAdded resets and retries.
			return
		end
		setState(player, "ClientReady")
		readyCharacter[player] = character
		readyBindable:Fire(player, character)
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player: Player)
		readyCharacter[player] = nil
	end)
end

function PlayerService:Start()
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

return PlayerService
