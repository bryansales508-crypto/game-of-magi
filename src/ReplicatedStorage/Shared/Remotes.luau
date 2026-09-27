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

local Remotes = {}

-- Declare every remote here, once. Kept empty except for the self-test remote.
Remotes.Definitions = {
	DebugPing = {
		kind = "Event",
		args = { Validate.string({ maxLen = 50 }) },
		rate = { count = 5, per = 1 },
	},
} :: { [string]: RemoteDef }

local NET_FOLDER_NAME = "Net"

-- ==================== Server ====================

Remotes.Server = {}

local instances: { [string]: RemoteEvent | RemoteFunction } = {}
local eventHandlers: { [string]: (player: Player, ...any) -> () } = {}
local functionHandlers: { [string]: (player: Player, ...any) -> ...any } = {}

-- [player][remoteName] = { count of calls in the current window, window start }
local rateState: { [Player]: { [string]: { count: number, windowStart: number } } } = {}

local function validateArgs(def: RemoteDef, args: { any }): (boolean, string?)
	if #args ~= #def.args then
		return false, string.format("expected %d argument(s), got %d", #def.args, #args)
	end
	for i, validator in def.args do
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

-- Checks a call against its definition (args + rate limit) without invoking
-- any handler. Exposed so SelfTestService can exercise it directly.
function Remotes.Server.CheckCall(name: string, player: Player, args: { any }): (boolean, string?)
	local def = Remotes.Definitions[name]
	if not def then
		return false, "unknown remote"
	end

	local okArgs, argReason = validateArgs(def, args)
	if not okArgs then
		return false, argReason
	end

	return checkRate(player, name, def)
end

local function makeEventDispatch(name: string)
	return function(player: Player, ...: any)
		local ok, reason = Remotes.Server.CheckCall(name, player, { ... })
		if not ok then
			log:Warn(string.format("dropped %s from %s: %s", name, player.Name, reason or "invalid"))
			return
		end
		local handler = eventHandlers[name]
		if handler then
			handler(player, ...)
		end
	end
end

local function makeFunctionDispatch(name: string)
	return function(player: Player, ...: any): ...any
		local ok, reason = Remotes.Server.CheckCall(name, player, { ... })
		if not ok then
			log:Warn(string.format("dropped %s from %s: %s", name, player.Name, reason or "invalid"))
			return nil
		end
		local handler = functionHandlers[name]
		if not handler then
			return nil
		end
		return handler(player, ...)
	end
end

function Remotes.Server.Init()
	local folder = ReplicatedStorage:FindFirstChild(NET_FOLDER_NAME) :: Folder?
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = NET_FOLDER_NAME
		folder.Parent = ReplicatedStorage
	end

	for name, def in Remotes.Definitions do
		local existing = (folder :: Folder):FindFirstChild(name)
		local instance: RemoteEvent | RemoteFunction
		if existing then
			instance = existing :: any
		elseif def.kind == "Event" then
			instance = Instance.new("RemoteEvent")
			instance.Name = name
			instance.Parent = folder
		else
			instance = Instance.new("RemoteFunction")
			instance.Name = name
			instance.Parent = folder
		end
		instances[name] = instance

		if def.kind == "Event" then
			(instance :: RemoteEvent).OnServerEvent:Connect(makeEventDispatch(name))
		else
			(instance :: RemoteFunction).OnServerInvoke = makeFunctionDispatch(name)
		end
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		rateState[player] = nil
	end)
end

function Remotes.Server.On(name: string, handler: (player: Player, ...any) -> ())
	eventHandlers[name] = handler
end

function Remotes.Server.Handle(name: string, handler: (player: Player, ...any) -> ...any)
	functionHandlers[name] = handler
end

function Remotes.Server.Fire(name: string, player: Player, ...: any)
	local instance = instances[name]
	if not instance then
		log:Warn(string.format("Fire(%s): remote not initialized", name))
		return
	end
	(instance :: RemoteEvent):FireClient(player, ...)
end

function Remotes.Server.FireAll(name: string, ...: any)
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
	local instance = getClientInstance(name) :: RemoteEvent
	instance:FireServer(...)
end

function Remotes.Client.On(name: string, handler: (...any) -> ())
	local instance = getClientInstance(name) :: RemoteEvent
	instance.OnClientEvent:Connect(handler)
end

local DEFAULT_INVOKE_TIMEOUT = 10

function Remotes.Client.Invoke(name: string, ...: any): ...any
	local instance = getClientInstance(name) :: RemoteFunction
	local args = table.pack(...)

	local result: { any }? = nil
	local errored = false
	task.spawn(function()
		local ok, packed = pcall(function()
			return table.pack(instance:InvokeServer(table.unpack(args, 1, args.n)))
		end)
		if ok then
			result = packed
		else
			errored = true
		end
	end)

	local deadline = os.clock() + DEFAULT_INVOKE_TIMEOUT
	while result == nil and not errored and os.clock() < deadline do
		task.wait(0.03)
	end

	if result == nil then
		return nil
	end
	return table.unpack(result, 1, (result :: any).n)
end

return Remotes
