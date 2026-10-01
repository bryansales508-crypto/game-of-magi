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
local Cities = require(script.Parent.Data.Cities)

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
	-- M1-05S: dev tools. DevService.Run also accepts the same command line
	-- through Player.Chatted; the remote just gives the dev panel a path
	-- that doesn't depend on the chat window.
	DevCommand = {
		kind = "Event",
		args = { Validate.string({ maxLen = 200 }) },
		rate = { count = 5, per = 1 },
	},
	-- Server -> client only; DevService never registers a handler for
	-- either, so a client calling these back just gets rate-limited/dropped.
	DevReply = {
		kind = "Event",
		args = {},
		rate = { count = 1, per = 10 },
	},
	DevState = {
		kind = "Event",
		args = {},
		rate = { count = 1, per = 10 },
	},
	-- M2-01: character creation. The server only acts on this while the
	-- save's Character.Gender == 0; see CharacterService.
	CreateCharacter = {
		kind = "Event",
		args = { Validate.number({ min = 1, max = 2, integer = true }), Validate.number({ min = 1, max = 3, integer = true }) },
		rate = { count = 3, per = 10 },
	},
	-- M2-02: server -> client only (AgeService never registers a handler,
	-- so a client calling this back is just dropped). Fired on every
	-- online birthday from Config.Aging.DeathStart; `fatal` means the
	-- return-to-the-Rukh scene follows.
	HeartAttack = {
		kind = "Event",
		args = { Validate.number({ min = 0, integer = true }), Validate.boolean() },
		rate = { count = 1, per = 5 },
	},
	-- M2-02: the client sends this once the return-to-the-Rukh scene ends;
	-- AgeService starts the new life on it (or after Config.Aging.SceneTimeout).
	RukhSceneDone = {
		kind = "Event",
		args = {},
		rate = { count = 2, per = 60 },
	},
	-- M3B-05: server -> client only (LifeService/AgeService never register a
	-- handler, same pattern as HeartAttack/CombatEvent). Fired instead of
	-- HeartAttack when Character.LivesLeft runs out on a real death (not old
	-- age) - the client plays the same return-to-the-Rukh scene either way
	-- and still answers with RukhSceneDone. The one table argument
	-- (`{cause = "lastLife"}`) isn't shape-checked for the same reason
	-- CombatEvent/RankUp's own data arguments aren't.
	Died = {
		kind = "Event",
		args = {},
		rate = { count = 1, per = 5 },
	},
	-- M3-02: MovementService. Intentions only - the server decides whether
	-- Run/Dash actually apply (stunned/knocked/blocking, cooldowns).
	Run = {
		kind = "Event",
		args = { Validate.boolean() },
		rate = { count = 4, per = 1 },
	},
	-- x/z are the dash direction in the character's own local space
	-- (forward/right), each clamped to [-1, 1]; MovementService normalises
	-- the resulting vector itself, so an off-axis diagonal like (1, 1) is
	-- still just "that diagonal direction", not a faster dash.
	Dash = {
		kind = "Event",
		args = { Validate.number({ min = -1, max = 1 }), Validate.number({ min = -1, max = 1 }) },
		rate = { count = 2, per = 1 },
	},
	-- M3-02/M3-03: server -> client only (MovementService and CombatService
	-- never register a handler, so a client calling this back is just
	-- dropped, same pattern as HeartAttack/RukhSceneDone). `data` isn't
	-- shape-checked here since nothing ever validates an outbound Fire/
	-- FireAll call; the second arg only matters if a client tries to
	-- invoke this itself, which goes nowhere.
	CombatEvent = {
		kind = "Event",
		args = { Validate.string({ maxLen = 32 }) },
		rate = { count = 1, per = 5 },
	},
	-- M3-FIX3-S/M3-FIX4-S: CombatService's animation-driven fighting-style
	-- flow. AttackStart is still just an intention (no args); AttackHit
	-- reports which chain hit's hit marker just played (1-based, matching
	-- the equipped style's Combat.Style.chain) - the client never reports
	-- WHAT it hit (C2 stays fixed), only that a marker played, and the
	-- server re-derives everything else (timing window, target, geometry)
	-- itself. Replaces the old single Attack() remote.
	AttackStart = {
		kind = "Event",
		args = {},
		rate = { count = 4, per = 1 },
	},
	AttackHit = {
		kind = "Event",
		args = { Validate.number({ min = 1, integer = true }) },
		rate = { count = 8, per = 1 },
	},
	-- M3-FIX5: "throw the next hit of my chain" - the second (third, ...)
	-- click of a combo, naming the chain hit it continues into (2-based: hit
	-- 1 always comes from AttackStart). Honoured only while the server is
	-- waiting for exactly that hit, inside Config.Combat.Chain's HitGap/
	-- ClickTimeout since the previous hit landed.
	AttackContinue = {
		kind = "Event",
		args = { Validate.number({ min = 2, integer = true }) },
		rate = { count = 8, per = 1 },
	},
	AttackCancel = {
		kind = "Event",
		args = {},
		rate = { count = 4, per = 1 },
	},
	Block = {
		kind = "Event",
		args = { Validate.boolean() },
		rate = { count = 4, per = 1 },
	},
	-- M3B-01: the combat stance. AttackStart/AttackCancel/Block are all
	-- rejected unless the character's InCombat attribute this produces is
	-- true (Dash/Run stay available regardless).
	SetStance = {
		kind = "Event",
		args = { Validate.boolean() },
		rate = { count = 4, per = 1 },
	},
	-- M4-01: RankService. Server -> client only (RankService never registers
	-- a handler, so a client calling either back is just dropped, same
	-- pattern as HeartAttack/CombatEvent); the one table argument isn't
	-- shape-checked here for the same reason CombatEvent's data argument
	-- isn't.
	RankUp = {
		kind = "Event",
		args = {},
		rate = { count = 3, per = 10 },
	},
	AlignmentChanged = {
		kind = "Event",
		args = {},
		rate = { count = 3, per = 10 },
	},
	-- M4-01: the client's answer to a pending RankUp choice. The server
	-- never trusts the string itself - only this index, into the three
	-- choices it already rolled and stored in the save.
	ChooseEpithet = {
		kind = "Event",
		args = { Validate.number({ min = 1, max = 3, integer = true }) },
		rate = { count = 3, per = 10 },
	},
	-- M5A-01: EconomyService. Server -> client only (EconomyService never
	-- registers a handler, so a client calling this back is just dropped,
	-- same pattern as HeartAttack/CombatEvent). One flavour line at a time -
	-- the old MarketHandler "the character says it in chat" feel (its
	-- ForcedChat remote), just through the new Net folder; the client posts
	-- the string to chat the same way InputHandler did for ForcedChat.
	CoinMessage = {
		kind = "Event",
		args = { Validate.string({ maxLen = 100 }) },
		rate = { count = 3, per = 5 },
	},
	-- M5C-01: delivery missions. MissionOpenBoard/MissionStart only ever
	-- name one of the seven known city keys (Shared/Data/Cities.Keys) -
	-- MissionService still checks the caller is actually near that city's
	-- delivery part, and that the destination is on the board it opened
	-- (AUDIT H7: the old server trusted any string the client sent).
	-- MissionBoard/MissionUpdate are server -> client only (MissionService
	-- never registers a handler for either, so a client calling one back is
	-- just dropped, same pattern as CombatEvent/RankUp); their one table
	-- argument isn't shape-checked for the same reason those aren't. A
	-- modifier entry (in a MissionBoard destination's `modifiers` and in
	-- MissionUpdate's own `modifiers`) is `{key, name, chance, text}` -
	-- `key` is the internal name (Shared/Data/Cities), `name` is the
	-- display name (REVIEW-M5C-01 H1). MissionUpdate also carries `failed`,
	-- an array of every modifier `key` already failed on this run
	-- (REVIEW-M5C-01B F3) - sent on EVERY update, most importantly the
	-- CourierLoop return leg's own `state = "Started"`, which rebuilds
	-- every pop-out from `modifiers` alone and would otherwise un-grey one
	-- that already failed on the first leg; the one-shot
	-- `state = "ModifierFailed", key = ...` update is still what greys a
	-- pop-out the moment it fails, `failed` is only for a rebuild to catch
	-- up, never a second trigger for the same key. The intercepted mark
	-- (Bryan): MissionBoard also carries `intercepted` (the player's current
	-- Progress.Intercepted stack count) and `offerMultiplier` (what that's
	-- worth right now, `MissionService.OfferMultiplier`) - purely
	-- informational headline numbers, since every destination's own `pay`
	-- is already multiplied by whatever the multiplier was when THAT
	-- destination was rolled/cached.
	MissionBoard = {
		kind = "Event",
		args = {},
		rate = { count = 1, per = 5 },
	},
	MissionOpenBoard = {
		kind = "Event",
		args = { Validate.string({ maxLen = 32, oneOf = Cities.Keys }) },
		rate = { count = 2, per = 1 },
	},
	MissionStart = {
		kind = "Event",
		args = { Validate.string({ maxLen = 32, oneOf = Cities.Keys }) },
		rate = { count = 2, per = 1 },
	},
	MissionExit = {
		kind = "Event",
		args = {},
		rate = { count = 2, per = 1 },
	},
	MissionUpdate = {
		kind = "Event",
		args = {},
		rate = { count = 3, per = 5 },
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

-- BUG-04/BUG-25 (M3-FIX-S): one dropped-call warning per player+remote per
-- window used to mean every OTHER drop in that same window (a flood of
-- rate-limit drops, say) logged nothing at all - silent, not just quiet.
-- The first drop in a window still logs immediately; everything else in
-- that window is counted here and flushed as one summary line when the
-- window closes (scheduled once per window, not per drop).
type DropWindow = {
	windowStart: number,
	total: number,
	reasonCounts: { [string]: number },
}
-- [player][remoteName] = the current window's drop tally
local warnState: { [Player]: { [string]: DropWindow } } = {}

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

-- Logs a window's leftover drops (everything after the first, which
-- already got its own immediate warning) as one summary line, grouped by
-- reason. Scheduled once per window at warnDropped's first drop; a no-op
-- if nothing else was dropped, or if this window was already superseded
-- (a newer one started, or the player's state was cleared entirely).
local function flushDropWindow(player: Player, name: string, window: DropWindow)
	local playerWarnState = warnState[player]
	if playerWarnState == nil or playerWarnState[name] ~= window then
		return
	end
	playerWarnState[name] = nil

	local extra = window.total - 1
	if extra <= 0 then
		return
	end

	local reasonParts: { string } = {}
	for reason, count in window.reasonCounts do
		table.insert(reasonParts, string.format("%s: %d", reason, count))
	end
	table.sort(reasonParts)
	log:Warn(string.format("%s from %s: dropped %d more call(s) this window (%s)", name, player.Name, extra, table.concat(reasonParts, ", ")))
end

local function warnDropped(player: Player, name: string, def: RemoteDef, reason: string?)
	local playerWarnState = warnState[player]
	if not playerWarnState then
		playerWarnState = {}
		warnState[player] = playerWarnState
	end

	local now = os.clock()
	local reasonKey = reason or "invalid"
	local window = playerWarnState[name]

	if window == nil or now - window.windowStart >= def.rate.per then
		window = { windowStart = now, total = 0, reasonCounts = {} }
		playerWarnState[name] = window
		log:Warn(string.format("dropped %s from %s: %s", name, player.Name, reasonKey))
		task.delay(def.rate.per, function()
			flushDropWindow(player, name, window :: DropWindow)
		end)
	end

	window.total += 1
	window.reasonCounts[reasonKey] = (window.reasonCounts[reasonKey] or 0) + 1
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
