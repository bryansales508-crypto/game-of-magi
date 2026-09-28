--!strict
-- One ProfileStore per server, one profile per player. Session-locked,
-- migrated to Config.Data.SchemaVersion, saved on leave and on shutdown
-- (ProfileStore itself binds to game:BindToClose and waits for every save
-- to finish; see the "We're done!" wait loop at the bottom of Packages/
-- ProfileStore.luau, so this module doesn't need its own BindToClose).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local SaveSchema = require(ReplicatedStorage.Shared.SaveSchema)
local ProfileStoreLib = require(ServerScriptService.Server.Packages.ProfileStore)

local log = Log.new("DataService")

type Data = SaveSchema.Data
type Profile = ProfileStoreLib.Profile<Data>

local KICK_MESSAGE = "Your save couldn't be loaded. Please rejoin in a moment."

-- Created once at module load (ProfileStore.New doesn't yield: it either
-- has the DataStore already or spawns a background wait for it).
--
-- Left untyped (rather than annotated ProfileStoreLib.ProfileStore<Data>):
-- that generic alias intersects an unexported recursive type internally,
-- and luau-lsp can't always unify two separately-instantiated copies of it
-- across a module boundary. Everything downstream of `startSession` works
-- with our own `Profile` alias instead, cast once at that boundary.
local rootStore = ProfileStoreLib.New(Config.Data.StoreName, SaveSchema.Template)

-- Flips to true (and stays true) the moment a real StartSessionAsync call
-- errors in Studio, or immediately if Config.Debug.FreshSave is set (also
-- Studio only): every following session in this server then uses
-- ProfileStore.Mock instead (nothing persists, every run starts fresh).
-- Studio play tests should never touch live saves. This must never happen
-- on a live server: a live server that silently switched to Mock would
-- serve every later player a blank save that's never written, with nothing
-- telling them (REVIEW-M1-03 H1) — a live StartSessionAsync error is a real
-- outage and gets a kick instead (see startSession below).
local useMock = Config.Debug.FreshSave and Config.IsStudio

local profiles: { [Player]: Profile } = {}
-- Sessions currently being started, so PlayerAdded firing twice for the same
-- player (once directly, once via Start()'s catch-up loop for a player who
-- joined just before Start ran) only ever runs the pipeline once
-- (REVIEW-M1-03 L6).
local loading: { [Player]: boolean } = {}

local loadedBindable = Instance.new("BindableEvent")

local DataService = {}
DataService.Loaded = loadedBindable.Event :: RBXScriptSignal

local function getStore(): any
	if useMock then
		return rootStore.Mock
	end
	return rootStore
end

local function profileKey(player: Player): string
	return Config.Debug.SaveScope .. "_" .. tostring(player.UserId)
end

-- Wraps one StartSessionAsync attempt so a thrown error (DataStore API
-- unavailable) doesn't blow through PlayerAdded uncaught.
local function attemptStartSession(key: string, cancelled: () -> boolean): (boolean, Profile?, string?)
	local ok, result = pcall(function()
		return getStore():StartSessionAsync(key, { Cancel = cancelled })
	end)
	if ok then
		return true, (result :: any) :: Profile?, nil
	end
	return false, nil, tostring(result)
end

local function startSession(player: Player): Profile?
	local key = profileKey(player)
	local function cancelled(): boolean
		return player.Parent ~= Players
	end

	local ok, profile, err = attemptStartSession(key, cancelled)

	if not ok and not useMock then
		if Config.IsStudio then
			log:Warn(
				string.format(
					"StartSessionAsync errored (%s); falling back to ProfileStore.Mock for the rest of this server's session (Studio only)",
					err or "unknown error"
				)
			)
			useMock = true
			ok, profile, err = attemptStartSession(key, cancelled)
		else
			-- Never fall back to Mock on a live server: that would silently
			-- serve every later player a blank save that's never written
			-- (REVIEW-M1-03 H1). A live StartSessionAsync error is an
			-- outage; kick and let the player rejoin once it clears.
			log:Error(string.format("StartSessionAsync errored for %s: %s", player.Name, err or "unknown error"))
			return nil
		end
	end

	if not ok then
		log:Error(string.format("StartSessionAsync failed for %s even with Mock: %s", player.Name, err or "unknown error"))
		return nil
	end

	return profile
end

local function kick(player: Player)
	if player:IsDescendantOf(Players) then
		player:Kick(KICK_MESSAGE)
	end
end

local function onPlayerAdded(player: Player)
	if profiles[player] ~= nil or loading[player] then
		-- Already loaded, or already loading (PlayerAdded firing while
		-- Start()'s catch-up loop is also handling this same player).
		return
	end
	loading[player] = true

	local profile = startSession(player)

	if profile == nil then
		-- Either the load failed, or the player left while it was loading
		-- (StartSessionAsync's Cancel condition), which also returns nil.
		loading[player] = nil
		kick(player)
		return
	end

	if player.Parent ~= Players then
		-- Rare race: the player left in the moment between StartSessionAsync
		-- returning and this check running. End the session instead of
		-- building a bridge for a player who's already gone.
		loading[player] = nil
		profile:EndSession()
		return
	end

	profile:AddUserId(player.UserId)
	profile:Reconcile()
	SaveSchema.Migrate(profile.Data)

	local data = profile.Data
	local now = os.time()
	local firstLoad = data.Meta.Created == 0
	if firstLoad then
		data.Meta.Created = now
		SaveSchema.NewLife(data)
	end
	data.Meta.LastSeen = now
	if data.Age.TimePassed == 0 then
		data.Age.TimePassed = now
	end

	profiles[player] = profile
	loading[player] = nil

	profile.OnSessionEnd:Connect(function()
		profiles[player] = nil
		loading[player] = nil
		kick(player)
	end)

	log:Info(string.format("Loaded save for %s (scope %s)", player.Name, Config.Debug.SaveScope))
	loadedBindable:Fire(player)
end

-- REVIEW-M5C-01B F1: plain synchronous callbacks, not a Players.
-- PlayerRemoving connection or a BindableEvent (whose Deferred signal
-- behavior wouldn't guarantee running before EndSession either, and either
-- way would depend on Init/Start connection order - "by luck", per the
-- review). profile:EndSession() fires ProfileStore's own OnSessionEnd
-- SYNCHRONOUSLY, before EndSession even returns (ProfileStore.luau), which
-- is what nils `profiles[player]` above - so another service's own
-- Players.PlayerRemoving handler (necessarily connected later, since
-- DataService.Init already ran before any other service's Start) can
-- already see DataService.Get return nil for a player that hasn't
-- technically left yet. A handler registered here is guaranteed to run
-- BEFORE that release, on every leave, regardless of when it registers.
-- Typed as a variadic return (not `()`) so pcall(handler, player) below
-- type-checks as (boolean, ...any) instead of just (boolean) - same trick
-- Main.server.luau's own ServiceModule type uses for Init/Start.
local releasingHandlers: { (Player) -> ...any } = {}

function DataService.OnReleasing(handler: (Player) -> ...any)
	table.insert(releasingHandlers, handler)
end

-- Runs every registered OnReleasing handler, then `endSession` - exposed
-- (same reasoning as ResetToTemplate above) so a self-test can prove the
-- ORDER itself (every handler before the release) with a fake player-like
-- stand-in and a plain callback, with no real Player/ProfileStore session
-- involved.
function DataService.RunReleasing(player: Player, endSession: () -> ())
	for _, handler in releasingHandlers do
		local ok, err = pcall(handler, player)
		if not ok then
			log:Warn(string.format("OnReleasing handler errored for %s: %s", player.Name, tostring(err)))
		end
	end
	endSession()
end

local function onPlayerRemoving(player: Player)
	DataService.RunReleasing(player, function()
		local profile = profiles[player]
		if profile and profile:IsActive() then
			profile:EndSession()
		end
	end)
end

function DataService.Get(player: Player): Data?
	local profile = profiles[player]
	if profile == nil then
		return nil
	end
	return profile.Data
end

function DataService.IsLoaded(player: Player): boolean
	return profiles[player] ~= nil
end

-- Event-driven, not a per-frame poll (REVIEW-M1-03 L8): suspends the
-- calling thread and resumes it from DataService.Loaded, PlayerRemoving, or
-- a task.delay timeout, whichever comes first.
function DataService.WaitFor(player: Player, timeout: number?): Data?
	local existing = DataService.Get(player)
	if existing then
		return existing
	end

	if not player:IsDescendantOf(Players) then
		return nil
	end

	local callingThread = coroutine.running()
	local settled = false

	local loadedConnection: RBXScriptConnection
	local removingConnection: RBXScriptConnection
	local timeoutThread: thread? = nil

	local function settle(result: Data?)
		if settled then
			return
		end
		settled = true
		loadedConnection:Disconnect()
		removingConnection:Disconnect()
		if timeoutThread then
			task.cancel(timeoutThread)
		end
		task.spawn(callingThread, result)
	end

	loadedConnection = DataService.Loaded:Connect(function(loadedPlayer: Player)
		if loadedPlayer == player then
			settle(DataService.Get(player))
		end
	end)

	removingConnection = Players.PlayerRemoving:Connect(function(leavingPlayer: Player)
		if leavingPlayer == player then
			settle(nil)
		end
	end)

	if timeout then
		timeoutThread = task.delay(timeout, function()
			settle(nil)
		end)
	end

	return coroutine.yield() :: Data?
end

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, inner in value do
		copy[key] = deepCopy(inner)
	end
	return copy
end

-- Resets `data` in place (same table identity, so every existing
-- DataService.Get(player) caller keeps seeing live data) to a fresh,
-- migrated template with SaveSchema.NewLife's random appearance roll
-- applied. Shared by Wipe and NewLife below - data-only, no Player or
-- ProfileStore involved, so self-tests can exercise the exact reset both of
-- them build on directly.
function DataService.ResetToTemplate(data: any)
	for key in data do
		data[key] = nil
	end
	-- Deep copy: the template's nested tables (Character, Gear, ...) must
	-- never be shared with a live profile, or the bridge mutating e.g.
	-- data.Gear.Hats in place would corrupt the template for every future
	-- wipe and every new player.
	for key, value in (SaveSchema.Template :: any) do
		data[key] = deepCopy(value)
	end
	SaveSchema.Migrate(data :: Data)
	SaveSchema.NewLife(data :: Data)
end

-- Resets Data to a fresh template in place, re-runs the first-load setup,
-- and refreshes the legacy bridge. Used by M1-05's dev "fresh save"
-- command. A wipe makes a brand-new player: Meta.Unlocks.Combat resets to
-- the template's false along with everything else (M3B-01, Bryan
-- 2026-09-28 - unlike NewLife below, nothing here is carried over).
function DataService.Wipe(player: Player)
	local profile = profiles[player]
	if profile == nil then
		log:Warn(string.format("Wipe requested for %s but no profile is loaded", player.Name))
		return
	end

	local data = profile.Data :: any
	DataService.ResetToTemplate(data)

	local now = os.time()
	data.Meta.Created = now
	data.Meta.LastSeen = now
	data.Age.TimePassed = now

	log:Info(string.format("Wiped save for %s", player.Name))
end

-- M2-02: a death's "completely fresh life" (DESIGN.md section 3a). Like
-- Wipe, but keeps Meta.Lives (incremented), Meta.Created (the save's
-- original creation time) and Meta.Unlocks.Combat (M3B-01: the combat
-- unlock is per-player forever, not per-life - a death isn't the same as a
-- dev reset, and losing it every life would defeat the point of earning it
-- once via the tutorial).
function DataService.NewLife(player: Player)
	local profile = profiles[player]
	if profile == nil then
		log:Warn(string.format("NewLife requested for %s but no profile is loaded", player.Name))
		return
	end

	local data = profile.Data :: any
	local keepLives = profile.Data.Meta.Lives + 1
	local keepCreated = profile.Data.Meta.Created
	local keepCombatUnlocked = profile.Data.Meta.Unlocks.Combat

	DataService.ResetToTemplate(data)

	local now = os.time()
	data.Meta.Created = keepCreated
	data.Meta.LastSeen = now
	data.Meta.Lives = keepLives
	data.Meta.Unlocks.Combat = keepCombatUnlocked
	data.Age.TimePassed = now

	log:Info(string.format("New life for %s (life #%d)", player.Name, keepLives))
end

function DataService.Save(player: Player)
	local profile = profiles[player]
	if profile == nil then
		log:Warn(string.format("Save requested for %s but no profile is loaded", player.Name))
		return
	end
	profile:Save()
end

function DataService:Init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

function DataService:Start()
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

return DataService
