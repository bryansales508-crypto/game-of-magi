--!strict
-- Registry of every remote. Remotes live under ReplicatedStorage.Net, created by the server at runtime. Every call is rate-limited and argument-validated on the server before a handler runs. Outbound-only remotes declare no args and no server handler; a client calling them back is dropped.

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

-- table.pack(...) result: .n is the real argument count, so a nil hole is never lost.
export type PackedArgs = { n: number, [number]: any }

local Remotes = {}

Remotes.Definitions = {
	DebugPing = {
		kind = "Event",
		args = { Validate.string({ maxLen = 50 }) },
		rate = { count = 5, per = 1 },
	},
	-- Fired once the client's loading screen is done. PlayerService ignores it unless the player's JoinState is "Loaded".
	ClientReady = {
		kind = "Event",
		args = {},
		rate = { count = 3, per = 10 },
	},
	-- Dev tools. DevService.Run also accepts the same command line through Player.Chatted; the remote gives the dev panel a path independent of chat.
	DevCommand = {
		kind = "Event",
		args = { Validate.string({ maxLen = 200 }) },
		rate = { count = 5, per = 1 },
	},
	-- Server -> client only.
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
	-- Server -> client only. A dev's chat command that is not a registered server command is forwarded here (full command line without the leading dot, e.g. "music next") so client-local commands (.region/.music/.lights) work from chat.
	DevLocalCommand = {
		kind = "Event",
		args = {},
		rate = { count = 1, per = 10 },
	},
	-- Character creation. The server only acts on it while the save's Character.Gender == 0; see CharacterService.
	CreateCharacter = {
		kind = "Event",
		args = { Validate.number({ min = 1, max = 2, integer = true }), Validate.number({ min = 1, max = 3, integer = true }) },
		rate = { count = 3, per = 10 },
	},
	-- Server -> client only. Fired on every online birthday from Config.Aging.DeathStart; `fatal` means the return-to-the-Rukh scene follows.
	HeartAttack = {
		kind = "Event",
		args = { Validate.number({ min = 0, integer = true }), Validate.boolean() },
		rate = { count = 1, per = 5 },
	},
	-- Sent once the return-to-the-Rukh scene ends; AgeService starts the new life on it (or after Config.Aging.SceneTimeout).
	RukhSceneDone = {
		kind = "Event",
		args = {},
		rate = { count = 2, per = 60 },
	},
	-- Server -> client only. Fired instead of HeartAttack when Character.LivesLeft runs out on a real death; the client plays the same Rukh scene and answers with RukhSceneDone. Its table argument (`{cause = "lastLife"}`) is not shape-checked since outbound calls are never validated.
	Died = {
		kind = "Event",
		args = {},
		rate = { count = 1, per = 5 },
	},
	-- Intentions only; the server decides whether Run/Dash apply (stunned/knocked/blocking, cooldowns).
	Run = {
		kind = "Event",
		args = { Validate.boolean() },
		rate = { count = 4, per = 1 },
	},
	-- x/z are the dash direction in the character's local space (forward/right), clamped to [-1, 1]; MovementService normalises the vector, so a diagonal is not a faster dash.
	Dash = {
		kind = "Event",
		args = { Validate.number({ min = -1, max = 1 }), Validate.number({ min = -1, max = 1 }) },
		rate = { count = 2, per = 1 },
	},
	-- Server -> client only. `data` is not shape-checked since outbound calls are never validated.
	CombatEvent = {
		kind = "Event",
		args = { Validate.string({ maxLen = 32 }) },
		rate = { count = 1, per = 5 },
	},
	-- Animation-driven fighting flow. AttackStart is an intention (no args). AttackHit reports which chain hit's marker just played (1-based, matching the equipped style's Combat.Style.chain); the client never reports what it hit, the server re-derives timing window, target and geometry itself.
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
	-- The second, third, ... click of a combo, naming the chain hit it continues into. The chain loops, so after the last hit the next click continues into hit 1 (hence min 1; the first hit 1 comes from AttackStart). Honoured only while the server is waiting for exactly that hit, inside Config.Combat.Chain's HitGap/ClickTimeout.
	AttackContinue = {
		kind = "Event",
		args = { Validate.number({ min = 1, integer = true }) },
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
	-- Combat stance. AttackStart/AttackCancel/Block are rejected unless the character's InCombat attribute (set by this) is true; Dash/Run stay available.
	SetStance = {
		kind = "Event",
		args = { Validate.boolean() },
		rate = { count = 4, per = 1 },
	},
	-- Server -> client only; the one table argument is not shape-checked.
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
	-- The client's answer to a pending RankUp choice. The server trusts only this index into the three choices it already rolled and stored in the save.
	ChooseEpithet = {
		kind = "Event",
		args = { Validate.number({ min = 1, max = 3, integer = true }) },
		rate = { count = 3, per = 10 },
	},
	-- Server -> client only. One flavour line at a time, posted to chat by the client as the character saying it.
	CoinMessage = {
		kind = "Event",
		args = { Validate.string({ maxLen = 100 }) },
		rate = { count = 3, per = 5 },
	},
	-- Delivery missions. MissionOpenBoard/MissionStart name one of the known city keys (Shared/Data/Cities.Keys); MissionService still checks proximity to the city's delivery part and that the destination is on the board the player opened. MissionBoard/MissionUpdate are server -> client only. A modifier entry is `{key, name, chance, text}` (`key` internal, `name` display). MissionUpdate also carries `failed`, every modifier key already failed this run, sent on every update so a rebuild (e.g. the CourierLoop return leg's `state = "Started"`) does not un-grey one; `state = "ModifierFailed", key = ...` is the one-shot that greys a pop-out. MissionBoard also carries `intercepted` (Progress.Intercepted stacks) and `offerMultiplier` (MissionService.OfferMultiplier), informational only: each destination's `pay` already includes the multiplier at the time it was rolled.
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
	-- Bounty hunting (the board and its posters are server-built world objects; there is no board remote). BountyState is server -> client only: `{ target = { userId, name, bounty }?, lastKnown = { x, y, z }?, revealed = boolean, reason? }`, sent when a bounty is taken or dropped (`target` nil, `reason` says why), when the bounty Tool is equipped/unequipped, and every tracking tick while it is equipped and something changed. Its table argument is not shape-checked since outbound calls are never validated. BountyToolEquipped is the client reporting that the bounty Tool went into or out of its hands; the server checks the Tool really is in the character before it acts, and tracking never depends on it.
	BountyState = {
		kind = "Event",
		args = {},
		rate = { count = 3, per = 5 },
	},
	-- Server -> client only: `{ text = string }`, a one-line player-facing notice (a refused take, "Bounty collected."). The client shows it as a chat system line.
	BountyNotice = {
		kind = "Event",
		args = {},
		rate = { count = 3, per = 5 },
	},
	BountyToolEquipped = {
		kind = "Event",
		args = { Validate.boolean() },
		rate = { count = 4, per = 1 },
	},
	-- Carrying a knocked-out player. CarryPickUp names the target by UserId (the server checks knocked, reach, both parties' states); CarryDrop puts them down; JailDeliver hands the carried player to the jail when standing at the dropoff. CarryState is server -> client only, sent to both parties: `{ carrying = { userId, name }?, carriedBy = { userId, name }?, canDeliver = boolean, dropoffPath = string? }` (both nil = a carry just ended; canDeliver/dropoffPath are for the carrier). Refusals are silent except for JailDeliver, whose reason arrives as a BountyNotice.
	CarryPickUp = {
		kind = "Event",
		args = { Validate.number({ min = 1, integer = true }) },
		rate = { count = 2, per = 1 },
	},
	CarryDrop = {
		kind = "Event",
		args = {},
		rate = { count = 2, per = 1 },
	},
	CarryState = {
		kind = "Event",
		args = {},
		rate = { count = 3, per = 5 },
	},
	JailDeliver = {
		kind = "Event",
		args = {},
		rate = { count = 2, per = 1 },
	},
	-- Gripping a knocked-out player (GripService). GripStart names the victim by UserId (the server checks knocked, reach, both parties' states); GripStop releases. GripState is server -> client only, sent to both parties on start, every tick and on stop: `{ gripping = { userId, name }?, grippedBy = { userId, name }?, progress = number (0..1), reason = string? }` (both nil = a grip just ended; `reason` only on that final send). A dummy gripper has userId 0.
	GripStart = {
		kind = "Event",
		args = { Validate.number({ min = 1, integer = true }) },
		rate = { count = 2, per = 1 },
	},
	GripStop = {
		kind = "Event",
		args = {},
		rate = { count = 3, per = 1 },
	},
	GripState = {
		kind = "Event",
		args = {},
		rate = { count = 3, per = 5 },
	},
} :: { [string]: RemoteDef }

local NET_FOLDER_NAME = "Net"


Remotes.Server = {}

local initialized = false
local instances: { [string]: RemoteEvent | RemoteFunction } = {}
-- Stored with a variadic return so pcall(handler, ...) type-checks as (boolean, ...any).
local eventHandlers: { [string]: (player: Player, ...any) -> ...any } = {}
local functionHandlers: { [string]: (player: Player, ...any) -> ...any } = {}

local rateState: { [Player]: { [string]: { count: number, windowStart: number } } } = {}

-- The first drop per player+remote per window logs immediately; the rest are counted and flushed as one summary line when the window closes.
type DropWindow = {
	windowStart: number,
	total: number,
	reasonCounts: { [string]: number },
}
local warnState: { [Player]: { [string]: DropWindow } } = {}

local function clearPlayerState(player: Player)
	rateState[player] = nil
	warnState[player] = nil
end

-- Clears a player's rate/warn state immediately. PlayerRemoving does this for real players; tests with a fake player table call it themselves.
Remotes.Server.ClearPlayerState = clearPlayerState

local function validateArgs(def: RemoteDef, args: PackedArgs): (boolean, string?)
	if args.n > #def.args then
		return false, string.format("expected at most %d argument(s), got %d", #def.args, args.n)
	end
	for i, validator in def.args do
		-- args[i] is nil for a hole and for an omitted trailing argument; Validate.optional allows either.
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

-- Checks a call against its definition without invoking a handler. The rate check runs first so a flood of bad calls is throttled instead of validating for free.
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

-- Exposed for SelfTestService: tests argument-count/hole handling against an ad-hoc definition.
Remotes.Server.ValidateArgsForTest = validateArgs

-- Logs a window's drops after the first as one summary line, grouped by reason. No-op if nothing else was dropped or the window was superseded or cleared.
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

-- Returns (true, ...result) on a normal reply. A server handler error is caught and logged by Remotes.Server and arrives here as (true, nil). (false, reason) means no reply: an undeclared remote, InvokeServer erroring client-side, or a timeout.
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

	-- task.defer (not task.spawn) guarantees this runs only after the caller has reached coroutine.yield(); otherwise a synchronous InvokeServer error would resume a caller that is not yet suspended and hang it forever.
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
