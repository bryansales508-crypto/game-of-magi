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
local LegacyBridge = require(script.Parent.LegacyBridge)

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
-- errors, or immediately if Config.Debug.FreshSave is set: every following
-- session in this server uses ProfileStore.Mock instead (nothing persists,
-- every run starts fresh). Studio play tests should never touch live saves.
local useMock = Config.Debug.FreshSave

local profiles: { [Player]: Profile } = {}

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
		log:Warn(
			string.format(
				"StartSessionAsync errored (%s); falling back to ProfileStore.Mock for the rest of this server's session",
				err or "unknown error"
			)
		)
		useMock = true
		ok, profile, err = attemptStartSession(key, cancelled)
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
	local profile = startSession(player)

	if profile == nil then
		-- Either the load failed, or the player left while it was loading
		-- (StartSessionAsync's Cancel condition), which also returns nil.
		kick(player)
		return
	end

	if player.Parent ~= Players then
		-- Rare race: the player left in the moment between StartSessionAsync
		-- returning and this check running. End the session instead of
		-- building a bridge for a player who's already gone.
		profile:EndSession()
		return
	end

	profile:AddUserId(player.UserId)
	profile:Reconcile()
	SaveSchema.Migrate(profile.Data)

	local data = profile.Data
	local now = os.time()
	if data.Meta.Created == 0 then
		data.Meta.Created = now
	end
	data.Meta.LastSeen = now
	if data.Age.TimePassed == 0 then
		data.Age.TimePassed = now
	end

	profiles[player] = profile

	profile.OnSessionEnd:Connect(function()
		profiles[player] = nil
		LegacyBridge.Destroy(player)
		kick(player)
	end)

	LegacyBridge.Build(player, data)

	log:Info(string.format("Loaded save for %s (scope %s)", player.Name, Config.Debug.SaveScope))
	loadedBindable:Fire(player)
end

local function onPlayerRemoving(player: Player)
	local profile = profiles[player]
	if profile and profile:IsActive() then
		profile:EndSession()
	end
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

function DataService.WaitFor(player: Player, timeout: number?): Data?
	local existing = DataService.Get(player)
	if existing then
		return existing
	end

	local deadline = if timeout then os.clock() + timeout else nil
	while profiles[player] == nil do
		if not player:IsDescendantOf(Players) then
			return nil
		end
		if deadline and os.clock() >= deadline then
			return nil
		end
		task.wait()
	end

	return DataService.Get(player)
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

-- Resets Data to a fresh template in place (same table identity, so every
-- existing DataService.Get(player) caller keeps seeing live data), re-runs
-- the first-load setup, and refreshes the legacy bridge. Used by M1-05's
-- dev "fresh save" command.
function DataService.Wipe(player: Player)
	local profile = profiles[player]
	if profile == nil then
		log:Warn(string.format("Wipe requested for %s but no profile is loaded", player.Name))
		return
	end

	local data = profile.Data :: any
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

	local now = os.time()
	data.Meta.Created = now
	data.Meta.LastSeen = now
	data.Age.TimePassed = now

	LegacyBridge.Refresh(player, profile.Data)
	log:Info(string.format("Wiped save for %s", player.Name))
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
