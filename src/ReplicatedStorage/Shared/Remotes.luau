--!strict
-- The single registry of every remote used by the new (renovated) code.
--
-- New remotes live under ReplicatedStorage.Net, created by the server at
-- runtime. The old ReplicatedStorage.Remotes folder is untouched; legacy
-- scripts keep using it until they're rebuilt.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Validate = require(script.Parent.Validate)
local Log = require(script.Parent.Log)

local log = Log.new("Remotes")

export type RemoteKind = "Event" | "Function"

export type RemoteDef = {
	kind: RemoteKind,
	args: { Validate.Validator },
	rate: { count: number, per: number },
}

-- table.pack(...) result: .n is the real argument count, so a nil in the
-- middle or at the end (a "hole") is never lost the way #args would lose it.
export type PackedArgs = { n: number, [number]: any }

local Remotes = {}

-- Declare every remote here, once.
Remotes.Definitions = {
	DebugPing = {
		kind = "Event",
		args = { Validate.string({ maxLen = 50 }) },
		rate = { count = 5, per = 1 },
	},
	-- M1-04S: fired by the client once its loading screen is done. PlayerService
	-- ignores it unless the player's JoinState is already "Loaded".
	ClientReady = {
		kind = "Event",
		args = {},
		rate = { count = 3, per = 10 },
	},
} :: { [string]: RemoteDef }

local NET_FOLDER_NAME = "Net"

-- ==================== Server ====================

Remotes.Server = {}

local initialized = false
local instances: { [string]: RemoteEvent | RemoteFunction } = {}
-- Stored with a variadic return (not `()`) so pcall(handler, ...) below
-- type-checks as (boolean, ...any) instead of just (boolean); On()'s public
-- signature below still only promises callers a no-return handler.
local eventHandlers: { [string]: (player: Player, ...any) -> ...any } = {}
local functionHandlers: { [string]: (player: Player, ...any) -> ...any } = {}

-- [player][remoteName] = { count of calls in the current window, window start }
local rateState: { [Player]: { [string]: { count: number, windowStart: number } } } = {}
-- [player][remoteName] = os.clock() the last "dropped" warning was logged
local warnState: { [Player]: { [string]: number } } = {}

local function clearPlayerState(player: Player)
	rateState[player] = nil
	warnState[player] = nil
end

-- Clears a player's rate/warn state immediately. PlayerRemoving does this
-- for real players; tests that use a fake player table should call it too,
-- since no PlayerRemoving event will ever fire for one.
Remotes.Server.ClearPlayerState = clearPlayerState

local function validateArgs(def: RemoteDef, args: PackedArgs): (boolean, string?)
	if args.n > #def.args then
		return false, string.format("expected at most %d argument(s), got %d", #def.args, args.n)
	end
	for i, validator in def.args do
		-- args[i] is nil both for a real hole and for an omitted trailing
		-- argument; Validate.optional(...) is what allows either through.
		local ok, reason = validator(args[i])
		if not ok then
			return false, string.format("argument %d: %s", i, reason or "invalid")
		end
	end
	return true
end

local function checkRate(player: Player, name: string, def: RemoteDef): (boolean, string?)
	local playerState = rateState[player]
	if not playerState then
		playerState = {}
		rateState[player] = playerState
	end

	local now = os.clock()
	local window = playerState[name]
	if not window or now - window.windowStart >= def.rate.per then
		playerState[name] = { count = 1, windowStart = now }
		return true
	end

	if window.count >= def.rate.count then
		return false, "rate limit exceeded"
	end

	window.count += 1
	return true
end

-- Checks a call against its definition (rate limit, then args) without
-- invoking any handler. Exposed so SelfTestService can exercise it
-- directly. The rate check runs first so a flood of bad calls still gets
-- throttled instead of validating for free every time.
function Remotes.Server.CheckCall(name: string, player: Player, args: PackedArgs): (boolean, string?)
	local def = Remotes.Definitions[name]
	if not def then
		return false, "unknown remote"
	end

	local okRate, rateReason = checkRate(player, name, def)
	if not okRate then
		return false, rateReason
	end

	return validateArgs(def, args)
end

-- Exposed for SelfTestService only: lets it test the argument-count/hole
-- handling directly, against an ad-hoc definition, without registering a
-- real remote.
Remotes.Server.ValidateArgsForTest = validateArgs

local function warnDropped(player: Player, name: string, def: RemoteDef, reason: string?)
	local playerWarnState = warnState[player]
	if not playerWarnState then
		playerWarnState = {}
		warnState[player] = playerWarnState
	end

	local now = os.clock()
	local last = playerWarnState[name]
	if last and now - last < def.rate.per then
		return
	end
	playerWarnState[name] = now

	log:Warn(string.format("dropped %s from %s: %s", name, player.Name, reason or "invalid"))
end

local function makeEventDispatch(name: string)
	return function(player: Player, ...: any)
		if player.Parent == nil then
			-- The player already left; don't resurrect their rate state.
			return
		end

		local def = Remotes.Definitions[name] :: RemoteDef
		local packed = table.pack(...) :: PackedArgs
		local ok, reason = Remotes.Server.CheckCall(name, player, packed)
		if not ok then
			warnDropped(player, name, def, reason)
			return
		end

		local handler = eventHandlers[name]
		if not handler then
			return
		end

		local success, err = pcall(handler, player, table.unpack(packed, 1, #def.args))
		if not success then
			log:Error(string.format("%s handler error (from %s): %s", name, player.Name, tostring(err)))
		end
	end
end

local function makeFunctionDispatch(name: string)
	return function(player: Player, ...: any): ...any
		if player.Parent == nil then
			return nil
		end

		local def = Remotes.Definitions[name] :: RemoteDef
		local packed = table.pack(...) :: PackedArgs
		local ok, reason = Remotes.Server.CheckCall(name, player, packed)
		if not ok then
			warnDropped(player, name, def, reason)
			return nil
		end

		local handler = functionHandlers[name]
		if not handler then
			return nil
		end

		local results = table.pack(pcall(handler, player, table.unpack(packed, 1, #def.args)))
		if not results[1] then
			log:Error(string.format("%s handler error (from %s): %s", name, player.Name, tostring(results[2])))
			return nil
		end
		return table.unpack(results, 2, results.n)
	end
end

local function getOrCreateNetFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(NET_FOLDER_NAME)
	if existing then
		if existing:IsA("Folder") then
			return existing
		end
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = NET_FOLDER_NAME
	folder.Parent = ReplicatedStorage
	return folder
end

local function getOrCreateRemote(folder: Folder, name: string, kind: RemoteKind): RemoteEvent | RemoteFunction
	local existing = folder:FindFirstChild(name)
	if existing then
		if kind == "Event" and existing:IsA("RemoteEvent") then
			return existing
		elseif kind == "Function" and existing:IsA("RemoteFunction") then
			return existing
		end
		existing:Destroy()
	end

	if kind == "Event" then
		local remoteEvent = Instance.new("RemoteEvent")
		remoteEvent.Name = name
		remoteEvent.Parent = folder
		return remoteEvent
	else
		local remoteFunction = Instance.new("RemoteFunction")
		remoteFunction.Name = name
		remoteFunction.Parent = folder
		return remoteFunction
	end
end

function Remotes.Server.Init()
	if initialized then
		return
	end
	initialized = true

	local folder = getOrCreateNetFolder()

	for name, def in Remotes.Definitions do
		local instance = getOrCreateRemote(folder, name, def.kind)
		instances[name] = instance

		if def.kind == "Event" then
			(instance :: RemoteEvent).OnServerEvent:Connect(makeEventDispatch(name))
		else
			(instance :: RemoteFunction).OnServerInvoke = makeFunctionDispatch(name)
		end
	end

	Players.PlayerRemoving:Connect(clearPlayerState)
end

function Remotes.Server.On(name: string, handler: (player: Player, ...any) -> ())
	local def = Remotes.Definitions[name]
	if not def or def.kind ~= "Event" then
		log:Error(string.format("On(%s): not a declared Event remote", name))
		return
	end
	eventHandlers[name] = handler
end

function Remotes.Server.Handle(name: string, handler: (player: Player, ...any) -> ...any)
	local def = Remotes.Definitions[name]
	if not def or def.kind ~= "Function" then
		log:Error(string.format("Handle(%s): not a declared Function remote", name))
		return
	end
	functionHandlers[name] = handler
end

function Remotes.Server.Fire(name: string, player: Player, ...: any)
	local def = Remotes.Definitions[name]
	if not def or def.kind ~= "Event" then
		log:Error(string.format("Fire(%s): not a declared Event remote", name))
		return
	end
	local instance = instances[name]
	if not instance then
		log:Warn(string.format("Fire(%s): remote not initialized", name))
		return
	end
	(instance :: RemoteEvent):FireClient(player, ...)
end

function Remotes.Server.FireAll(name: string, ...: any)
	local def = Remotes.Definitions[name]
	if not def or def.kind ~= "Event" then
		log:Error(string.format("FireAll(%s): not a declared Event remote", name))
		return
	end
	local instance = instances[name]
	if not instance then
		log:Warn(string.format("FireAll(%s): remote not initialized", name))
		return
	end
	(instance :: RemoteEvent):FireAllClients(...)
end

-- ==================== Client ====================

Remotes.Client = {}

local function waitForNetFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild(NET_FOLDER_NAME)
	if folder then
		return folder :: Folder
	end
	return ReplicatedStorage:WaitForChild(NET_FOLDER_NAME) :: Folder
end

local function getClientInstance(name: string): Instance
	local folder = waitForNetFolder()
	return folder:WaitForChild(name)
end

function Remotes.Client.Fire(name: string, ...: any)
	local def = Remotes.Definitions[name]
	if not def or def.kind ~= "Event" then
		log:Error(string.format("Fire(%s): not a declared Event remote", name))
		return
	end
	local instance = getClientInstance(name) :: RemoteEvent
	instance:FireServer(...)
end

function Remotes.Client.On(name: string, handler: (...any) -> ())
	local def = Remotes.Definitions[name]
	if not def or def.kind ~= "Event" then
		log:Error(string.format("On(%s): not a declared Event remote", name))
		return
	end
	local instance = getClientInstance(name) :: RemoteEvent
	instance.OnClientEvent:Connect(handler)
end

local DEFAULT_INVOKE_TIMEOUT = 10

-- Returns (true, ...result) on a normal reply. A server-side handler error
-- is caught by Remotes.Server's own pcall (and logged there via Log:Error);
-- it never reaches the client as a thrown error, so it arrives here as
-- (true, nil), not (false, reason). (false, reason) means the call itself
-- never got a reply: an unknown/undeclared remote, InvokeServer erroring
-- client-side (e.g. a bad argument type), or a timeout. Uses the calling
-- thread's own coroutine (no poll loop, no leaked thread waiting on a
-- result nobody will read).
function Remotes.Client.Invoke(name: string, ...: any): (boolean, ...any)
	local def = Remotes.Definitions[name]
	if not def or def.kind ~= "Function" then
		log:Error(string.format("Invoke(%s): not a declared Function remote", name))
		return false, "unknown remote"
	end

	local instance = getClientInstance(name) :: RemoteFunction
	local args = table.pack(...)
	local caller = coroutine.running()
	local settled = false

	local timeoutThread = task.delay(DEFAULT_INVOKE_TIMEOUT, function()
		if settled then
			return
		end
		settled = true
		task.spawn(caller, false, "timeout")
	end)

	-- task.defer (not task.spawn) guarantees this never runs until the
	-- caller below has actually reached coroutine.yield(). task.spawn would
	-- run this immediately, inline, on the calling thread; if InvokeServer
	-- then errored synchronously (before yielding), it would try to resume
	-- `caller` while `caller` is still running this very statement, not yet
	-- suspended, and the caller would then hang in coroutine.yield() forever
	-- with no one left to resume it.
	task.defer(function()
		local results = table.pack(pcall(function()
			return instance:InvokeServer(table.unpack(args, 1, args.n))
		end))
		if settled then
			return
		end
		settled = true
		task.cancel(timeoutThread)

		if results[1] then
			task.spawn(caller, true, table.unpack(results, 2, results.n))
		else
			task.spawn(caller, false, tostring(results[2]))
		end
	end)

	return coroutine.yield()
end

return Remotes
