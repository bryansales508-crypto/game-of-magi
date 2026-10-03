--!strict
-- One ProfileStore per server, one profile per player. Session-locked, migrated to
-- Config.Data.SchemaVersion, saved on leave. ProfileStore binds to BindToClose itself, so this
-- module has none.

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

-- Created once at module load. Left untyped: the generic ProfileStore alias intersects an
-- unexported recursive type that luau-lsp can't unify across modules; downstream code uses our
-- own `Profile` alias, cast once at startSession.
local rootStore = ProfileStoreLib.New(Config.Data.StoreName, SaveSchema.Template)

-- True once a StartSessionAsync call errors in Studio (or Config.Debug.FreshSave is set): later
-- sessions use ProfileStore.Mock so Studio play tests never touch live saves. Never happens on
-- a live server: a live error kicks the player instead (see startSession).
local useMock = Config.Debug.FreshSave and Config.IsStudio

local profiles: { [Player]: Profile } = {}
-- Sessions being started, so PlayerAdded and Start()'s catch-up loop don't run the pipeline
-- twice for one player.
local loading: { [Player]: boolean } = {}

local loadedBindable = Instance.new("BindableEvent")
-- Fires after a player's save is replaced in place (Wipe/NewLife: same `data` table, new
-- contents) so anything mirroring the save onto attributes can re-publish. Not fired for a
-- normal load.
local replacedBindable = Instance.new("BindableEvent")

local DataService = {}
DataService.Loaded = loadedBindable.Event :: RBXScriptSignal
DataService.Replaced = replacedBindable.Event :: RBXScriptSignal

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
			-- Never fall back to Mock on a live server: a blank, never-written save would be
			-- served silently. Kick and let the player rejoin.
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
		-- Already loaded or loading.
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
		-- The player left between StartSessionAsync returning and this check: end the session.
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

-- Plain synchronous callbacks run BEFORE the profile is released (EndSession fires OnSessionEnd
-- synchronously, which nils profiles[player]), so handlers can still call DataService.Get on
-- every leave regardless of registration order. Typed as a variadic return so pcall(handler,
-- player) type-checks.
local releasingHandlers: { (Player) -> ...any } = {}

function DataService.OnReleasing(handler: (Player) -> ...any)
	table.insert(releasingHandlers, handler)
end

-- Runs every OnReleasing handler, then `endSession`. Exposed so a self-test can prove the
-- ordering without a real session.
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

-- Suspends the calling thread until DataService.Loaded, PlayerRemoving, or a timeout, whichever
-- is first.
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

-- Resets `data` in place (same table identity, so existing Get callers see live data) to a
-- fresh migrated template with NewLife's random appearance roll. Data-only; shared by Wipe and
-- NewLife.
function DataService.ResetToTemplate(data: any)
	for key in data do
		data[key] = nil
	end
	-- Deep copy so live profiles never share nested tables with the template.
	for key, value in (SaveSchema.Template :: any) do
		data[key] = deepCopy(value)
	end
	SaveSchema.Migrate(data :: Data)
	SaveSchema.NewLife(data :: Data)
end

-- Resets Data to a fresh template in place and re-runs first-load setup (dev 'fresh save'
-- command). Everything resets, including Meta.Unlocks.Combat.
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
	replacedBindable:Fire(player)
end

-- A death's completely fresh life. Like Wipe, but keeps Meta.Lives (incremented), Meta.Created
-- and Meta.Unlocks.Combat (earned once, per player forever).
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
	replacedBindable:Fire(player)
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
