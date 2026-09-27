--!strict
-- The join pipeline: load -> character ready -> spawn -> ready, in order,
-- with no one-time signal that can be missed. Replaces the old MainScreen
-- remote race (AUDIT H3/P1/M9) and the old LocationHandler/Protection.
--
-- State lives entirely in one Player attribute, `JoinState`, so anything
-- (old or new code) can just read or watch it instead of coordinating
-- through a fragile chain of events:
--   "Loading" -> "Loaded" -> "Ready", reset to "Loading" on every respawn.

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

local PlayerService = {}
PlayerService.Ready = readyBindable.Event :: RBXScriptSignal

-- Pure: no Player needed, so SelfTestService can exercise every transition
-- directly. This is the ONLY place the state machine's rules live; setState
-- below just applies its result to a Player's attribute.
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
	return PlayerService.GetState(player) == "Ready"
end

-- Applies one event to `player`'s JoinState and writes the result back as
-- the attribute (a Respawn is written even if the state was already
-- "Loading", since it's the reset signal every respawn must (re)send).
local function setState(player: Player, event: JoinEvent): JoinState
	local current: JoinState = PlayerService.GetState(player) or "Loading"
	local nextState: JoinState = PlayerService.NextJoinState(current, event)
	if nextState ~= current or event == "Respawn" then
		player:SetAttribute("JoinState", nextState)
	end
	return nextState
end

-- Waits for JoinState == "Ready" and returns the character it became ready
-- with (nil on timeout or if the player leaves first). Every loop iteration
-- re-checks player.Parent so a leaving player never leaks the thread.
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

-- Resolves Workspace.MAP.Spawns.QarzinSpawn fresh every call (cheap once the
-- map is loaded: WaitForChild returns instantly for an existing child), with
-- a bounded wait and a logged error instead of hanging forever if the map
-- isn't there.
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

	return qarzin.CFrame + Vector3.new(0, SPAWN_RAISE_STUDS, 0)
end

-- Logs once (never kicks: the old 30s kick during character creation was
-- H3) if this exact character is still "Loading" after STUCK_LOADING_SECONDS.
-- Guarded against a later respawn: if player.Character has moved on, this
-- watchdog is stale and says nothing.
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

	-- Usually already loaded by the time a character exists; this only
	-- really waits on a fast auto-spawn racing PlayerAdded's own load.
	local data = DataService.WaitFor(player)
	if data == nil or player.Parent ~= Players or player.Character ~= character then
		return
	end

	setState(player, "CharacterPlaced")
end

local function onPlayerAdded(player: Player)
	if PlayerService.GetState(player) ~= nil then
		-- Start() and PlayerAdded can both reach a player that joined right
		-- before Start() ran; only run the pipeline once per player.
		return
	end

	player:SetAttribute("JoinState", "Loading")
	player.CharacterAdded:Connect(function(character: Model)
		onCharacterAdded(player, character)
	end)

	local data = DataService.WaitFor(player)
	if data == nil then
		-- DataService already kicked (or is kicking) this player.
		return
	end
end

function PlayerService:Init()
	Remotes.Server.On("ClientReady", function(player: Player)
		if PlayerService.GetState(player) ~= "Loaded" then
			return
		end
		setState(player, "ClientReady")
		local character = player.Character
		if character then
			readyBindable:Fire(player, character)
		end
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
end

function PlayerService:Start()
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

return PlayerService
