--!strict
-- The one owner of combat statuses (M3-01, TRIAGE #13, fixes AUDIT M18).
-- Keyed by the combatant's character Model, never by Player: NPCs are
-- combatants exactly like players (Bryan, 2026-09-27), and this service
-- must not assume a Player exists. Players are registered automatically on
-- PlayerService.Ready below; NPCs are registered by M3-04's NpcService.
--
-- Statuses: Hit, Stun, Knocked, Ragdoll, Block, BlockBroken, TrueStun.
-- Anything else can still be Applied/Removed (the API is generic), it just
-- won't get an attribute or a bridge marker unless added to the tables
-- below.
--
-- Bridge: every Apply/Remove also creates/destroys the matching Value
-- under character.Effects, with the same Name/ClassName/Value semantics
-- the old DamageHandler/InteractionsDesign/EffectsService used (see
-- SYSTEMS.md section 10 and those two files on main), so old readers
-- (missions, regions, EffectsService's own ragdoll/blind-screen/sound
-- reactions) keep working until M3-03/M3-06 replace them. StatusService
-- only owns the markers; it does not ragdoll, blind or make sound itself
-- (EffectsService still does, reacting to the same markers as before).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Log = require(ReplicatedStorage.Shared.Log)
local PlayerService = require(script.Parent.PlayerService)

local log = Log.new("StatusService")

export type StatusInfo = {
	-- os.clock() this status expires at, or nil for "stays until Removed".
	expiresAt: number?,
	-- The duration originally passed to Apply (nil for "no duration"),
	-- kept alongside expiresAt so a bridge marker's Value can be built from
	-- it without redoing the os.clock() math on every write.
	duration: number?,
	data: any?,
}

type RegisteredEntry = {
	owner: Player?,
	statuses: { [string]: StatusInfo },
	effectsFolder: Folder?,
	ancestryConn: RBXScriptConnection?,
}

local TICK = 0.1
local EFFECTS_WAIT_TIMEOUT = 5

-- ==================== attribute mirroring ====================
-- Character attributes clients read directly (cheap replication, same
-- pattern as HealthService's player attributes). Only these four statuses
-- get one; everything else is StatusService-internal/bridge-only.

local ATTRIBUTE_FOR: { [string]: string } = {
	Stun = "Stunned",
	Knocked = "Knocked",
	Block = "Blocking",
	TrueStun = "TrueStunned",
}

-- ==================== bridge marker shapes ====================
-- className: what the old code expected at character.Effects[status].
-- value: computes the Value to set on Apply (or on a refreshing re-Apply);
-- returning nil leaves the instance's default Value alone, matching
-- statuses the old code never wrote a meaningful Value for (Stun, Ragdoll,
-- BlockBroken, TrueStun all default-constructed their Value in the old
-- scripts too).

type BridgeSpec = {
	className: "StringValue" | "IntValue",
	value: (data: any?, duration: number?) -> any?,
}

local BRIDGE: { [string]: BridgeSpec } = {
	-- Old DamageHandler always set Value = "Fist" regardless of weapon;
	-- data.kind lets a caller override once other weapons exist (M5).
	Hit = {
		className = "StringValue",
		value = function(data: any?): any?
			if type(data) == "table" and data.kind ~= nil then
				return data.kind
			end
			return "Fist"
		end,
	},
	Stun = {
		className = "StringValue",
		value = function(): any?
			return nil
		end,
	},
	-- Old DamageHandler: Value = math.random(3,5), a getup countdown
	-- HealthService's reviveLoop ticks down on its own (unchanged, still
	-- runs until M3-03 rewires the knockout path). Ours is the authority on
	-- when Knocked actually gets Removed; the Value here is just what that
	-- old countdown display starts from.
	Knocked = {
		className = "IntValue",
		value = function(_data: any?, duration: number?): any?
			return math.max(0, math.ceil(duration or 0))
		end,
	},
	Ragdoll = {
		className = "IntValue",
		value = function(): any?
			return nil
		end,
	},
	-- Old Blocking remote: IntValue, 1 during the parry window then 0.
	-- CombatService (M3-03) drives that transition itself by calling
	-- Apply(character, "Block", nil, {value = 0}) once the window elapses;
	-- StatusService just mirrors whatever value it's given, defaulting to 1
	-- (matching the old remote's own Block(true) behavior).
	Block = {
		className = "IntValue",
		value = function(data: any?): any?
			if type(data) == "table" and data.value ~= nil then
				return data.value
			end
			return 1
		end,
	},
	BlockBroken = {
		className = "IntValue",
		value = function(): any?
			return nil
		end,
	},
	TrueStun = {
		className = "StringValue",
		value = function(): any?
			return nil
		end,
	},
}

-- ==================== state ====================

local registered: { [Model]: RegisteredEntry } = {}
local changedBindable = Instance.new("BindableEvent")

local StatusService = {}
StatusService.Changed = changedBindable.Event :: RBXScriptSignal

-- ==================== effects folder (bridge home) ====================

-- Never yields the caller. Looks once, synchronously; if the folder isn't
-- there yet, resolves it in the background (WaitForChild, then create if
-- still missing) so Register never blocks a hot path. Bridge writes before
-- that resolves just silently skip (internal state/attributes still work
-- regardless), which is a lot better than either yielding Apply or racing
-- EffectsService to create a second "Effects" folder.
local function resolveEffectsFolder(character: Model, entry: RegisteredEntry)
	local existing = character:FindFirstChild("Effects")
	if existing and existing:IsA("Folder") then
		entry.effectsFolder = existing
		return
	end

	task.spawn(function()
		local waited = character:WaitForChild("Effects", EFFECTS_WAIT_TIMEOUT)
		if registered[character] ~= entry then
			-- Unregistered (or re-registered fresh) while we were waiting.
			return
		end
		if waited and waited:IsA("Folder") then
			entry.effectsFolder = waited
			return
		end
		if character.Parent == nil then
			return
		end
		local ok, result = pcall(function()
			local f = Instance.new("Folder")
			f.Name = "Effects"
			f.Parent = character
			return f
		end)
		if ok then
			entry.effectsFolder = result :: Folder
		else
			log:Warn(string.format("couldn't create %s's Effects bridge folder: %s", character.Name, tostring(result)))
		end
	end)
end

-- ==================== register / unregister ====================

function StatusService.Register(character: Model, owner: Player?)
	local existing = registered[character]
	if existing then
		existing.owner = owner
		return
	end

	local entry: RegisteredEntry = { owner = owner, statuses = {} }
	registered[character] = entry

	local ok, conn = pcall(function()
		return character.AncestryChanged:Connect(function(_child, parent)
			if parent == nil then
				StatusService.Unregister(character)
			end
		end)
	end)
	if ok then
		entry.ancestryConn = conn
	end

	resolveEffectsFolder(character, entry)
end

function StatusService.IsRegistered(character: Model): boolean
	return registered[character] ~= nil
end

-- Safe to call on a character that's already gone (AUDIT M18): every write
-- below is guarded, and a missing entry is just a no-op.
function StatusService.Unregister(character: Model)
	local entry = registered[character]
	if entry == nil then
		return
	end
	registered[character] = nil

	if entry.ancestryConn then
		entry.ancestryConn:Disconnect()
	end

	for status in entry.statuses do
		local attrName = ATTRIBUTE_FOR[status]
		if attrName then
			pcall(function()
				character:SetAttribute(attrName, false)
			end)
		end
	end
end

-- ==================== bridge writes ====================

local function writeBridgeMarker(character: Model, status: string, info: StatusInfo)
	local spec = BRIDGE[status]
	local entry = registered[character]
	if spec == nil or entry == nil or entry.effectsFolder == nil then
		return
	end
	local effects = entry.effectsFolder

	local ok, err = pcall(function()
		local found = effects:FindFirstChild(status)
		local instance: Instance
		if found and found:IsA(spec.className) then
			instance = found
		else
			if found then
				found:Destroy()
			end
			local created = Instance.new(spec.className)
			created.Name = status
			created.Parent = effects
			instance = created
		end

		local value = spec.value(info.data, info.duration)
		if value ~= nil then
			(instance :: any).Value = value
		end

		-- Old DamageHandler parented a StringValue named after the
		-- attacker under the Knocked marker itself (SYSTEMS 10's "personKnocker").
		if status == "Knocked" and type(info.data) == "table" and type(info.data.by) == "string" then
			local byName = info.data.by :: string
			if instance:FindFirstChild(byName) == nil then
				local marker = Instance.new("StringValue")
				marker.Name = byName
				marker.Parent = instance
			end
		end
	end)
	if not ok then
		log:Warn(string.format("couldn't write %s's %s bridge marker: %s", character.Name, status, tostring(err)))
	end
end

local function removeBridgeMarker(character: Model, status: string)
	local entry = registered[character]
	if entry == nil or entry.effectsFolder == nil then
		return
	end
	local ok, err = pcall(function()
		local instance = (entry.effectsFolder :: Folder):FindFirstChild(status)
		if instance then
			instance:Destroy()
		end
	end)
	if not ok then
		log:Warn(string.format("couldn't remove %s's %s bridge marker: %s", character.Name, status, tostring(err)))
	end
end

local function mirrorAttribute(character: Model, status: string, active: boolean)
	local attrName = ATTRIBUTE_FOR[status]
	if attrName == nil then
		return
	end
	pcall(function()
		character:SetAttribute(attrName, active)
	end)
end

-- ==================== public API ====================

-- Applies (or refreshes) a status. `duration` (seconds) auto-expires it on
-- the shared loop below; nil means it stays until Remove is called
-- explicitly (e.g. Block, which CombatService removes on Block(false)).
-- Re-applying an already-active status refreshes its duration/data (and
-- the bridge marker's Value) without re-firing Changed, since the active
-- state itself didn't change.
function StatusService.Apply(character: Model, status: string, duration: number?, data: any?)
	if type(status) ~= "string" or status == "" then
		return
	end

	local entry = registered[character]
	if entry == nil then
		if character.Parent == nil then
			-- Gone before it was ever registered; nothing to track.
			return
		end
		StatusService.Register(character, nil)
		entry = registered[character]
		if entry == nil then
			return
		end
	end

	local wasActive = entry.statuses[status] ~= nil
	local info: StatusInfo = {
		expiresAt = if duration then os.clock() + duration else nil,
		duration = duration,
		data = data,
	}
	entry.statuses[status] = info

	writeBridgeMarker(character, status, info)
	mirrorAttribute(character, status, true)

	if not wasActive then
		changedBindable:Fire(character, status, true)
	end
end

-- Safe on a character that's already gone (AUDIT M18): a missing entry or
-- a status that isn't active is just a no-op, never an error.
function StatusService.Remove(character: Model, status: string)
	local entry = registered[character]
	if entry == nil or entry.statuses[status] == nil then
		return
	end
	entry.statuses[status] = nil

	removeBridgeMarker(character, status)
	mirrorAttribute(character, status, false)
	changedBindable:Fire(character, status, false)
end

function StatusService.Has(character: Model, status: string): boolean
	local entry = registered[character]
	return entry ~= nil and entry.statuses[status] ~= nil
end

function StatusService.Get(character: Model, status: string): StatusInfo?
	local entry = registered[character]
	if entry == nil then
		return nil
	end
	return entry.statuses[status]
end

-- ==================== service ====================

function StatusService:Init()
	PlayerService.Ready:Connect(function(player: Player, character: Model)
		StatusService.Register(character, player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		local character = player.Character
		if character then
			StatusService.Unregister(character)
		end
	end)
end

function StatusService:Start()
	-- One shared loop for every combatant's status durations (players and
	-- NPCs alike): no per-status task.delay/thread, so nothing leaks on
	-- respawn or death (AUDIT M18's "hooks miss early markers" and the
	-- wider "no leaked listeners or threads" rule for M3).
	task.spawn(function()
		while true do
			task.wait(TICK)
			local now = os.clock()
			for character, entry in registered do
				if character.Parent == nil then
					StatusService.Unregister(character)
					continue
				end
				for status, info in entry.statuses do
					if info.expiresAt and now >= info.expiresAt then
						StatusService.Remove(character, status)
					end
				end
			end
		end
	end)
end

return StatusService
