--!strict
-- The one owner of combat statuses. Keyed by the combatant's character Model, never by
-- Player: NPCs are combatants exactly like players. Players are registered automatically
-- on PlayerService.Ready; NpcService registers NPCs.
--
-- Statuses: Carrying, Carried, Jailed (set by CarryService/JailService; attribute only), Hit, Stun, Knocked, Ragdoll, Block, BlockBroken, TrueStun, plus LightStun (a
-- landed Light's softer stun: can't block/parry, can still attack or dash), Recovery (a
-- punished feint: can't attack, block or dash) and Bleed (stacked; data = {stacks,
-- config}, ticked by HealthService). Anything else can still be Applied/Removed (the API
-- is generic) but gets no attribute or bridge marker unless added to the tables below.
--
-- Bridge: every Apply/Remove also creates/destroys the matching Value under
-- character.Effects (the Name/ClassName/Value semantics legacy readers expect: missions,
-- regions, EffectsService's ragdoll/blind-screen/sound reactions). StatusService only owns
-- the markers; EffectsService reacts to them. The bridge is two-way: if another script
-- destroys a marker, StatusService treats that as the status ending.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Log = require(ReplicatedStorage.Shared.Log)
local Combat = require(ReplicatedStorage.Shared.Data.Combat)
local PlayerService = require(script.Parent.PlayerService)

local log = Log.new("StatusService")

export type StatusInfo = {
	-- os.clock() this status expires at, or nil for "stays until Removed".
	expiresAt: number?,
	-- The duration originally passed to Apply (nil for none), so a marker's Value can be
	-- built without redoing the clock math.
	duration: number?,
	data: any?,
	-- Block only: os.clock() at which the parry window (value 1) flips to the block hold
	-- (value 0), or nil once flipped or never scheduled.
	parryFlipAt: number?,
}

type RegisteredEntry = {
	owner: Player?,
	statuses: { [string]: StatusInfo },
	effectsFolder: Folder?,
	ancestryConn: RBXScriptConnection?,
	effectsRemovedConn: RBXScriptConnection?,
	humanoidDiedConn: RBXScriptConnection?,
	-- Name -> in-flight self-Destroy() count, so the Effects.ChildRemoved bridge can tell
	-- our own destroy from someone else's under deferred signals.
	selfDestroying: { [string]: number },
}

local TICK = 0.1
local EFFECTS_RETRY = 1
local NPC_EFFECTS_WAIT_TIMEOUT = 5

-- Character attributes clients read directly (cheap replication). Only these statuses
-- get one; the rest are internal/bridge-only.

local ATTRIBUTE_FOR: { [string]: string } = {
	Stun = "Stunned",
	Knocked = "Knocked",
	Block = "Blocking",
	TrueStun = "TrueStunned",
	LightStun = "LightStunned",
	Recovery = "Recovering",
	-- Carry and jail (CarryService/JailService); no duration, removed explicitly.
	Carrying = "Carrying",
	Carried = "Carried",
	Jailed = "Jailed",
	-- Bleed's attribute is a stack count, not a boolean (see mirrorAttribute).
	Bleed = "Bleed",
}

-- className: the instance class at character.Effects[status]. value: computes the Value
-- to set on Apply (or a refreshing re-Apply); returning nil leaves the default Value.
-- alwaysRecreate: a brand-new Instance per Apply, because several readers
-- (EffectsService sound/particle, FaceControl's hurt face, PhysicalHandler's stagger, the
-- FragilePackage mission) key off ChildAdded; reusing one Hit marker would go silent
-- after the first hit.

type BridgeSpec = {
	className: "StringValue" | "IntValue",
	value: (data: any?, duration: number?) -> any?,
	alwaysRecreate: boolean?,
}

local BRIDGE: { [string]: BridgeSpec } = {
	-- Value defaults to "Fist"; data.kind overrides it for other weapons.
	Hit = {
		className = "StringValue",
		value = function(data: any?): any?
			if type(data) == "table" and data.kind ~= nil then
				return data.kind
			end
			return "Fist"
		end,
		alwaysRecreate = true,
	},
	Stun = {
		className = "StringValue",
		value = function(): any?
			return nil
		end,
	},
	-- Value is a getup countdown (math.random(3,5)) that HealthService's reviveLoop ticks
	-- down. StatusService is the authority on when Knocked is Removed; the Value is only
	-- the countdown display's start.
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
	-- IntValue: 1 during the parry window, then 0. StatusService flips 1 -> 0 after
	-- Combat.Block.parryWindow on the shared loop; a caller Applies once with {value = 1}
	-- (the default) and never re-Applies to flip it.
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


local registered: { [Model]: RegisteredEntry } = {}
local changedBindable = Instance.new("BindableEvent")

local StatusService = {}
StatusService.Changed = changedBindable.Event :: RBXScriptSignal

-- Defined before the Effects-folder resolution below, which backfills through this function.

local function writeBridgeMarker(character: Model, status: string, info: StatusInfo)
	local spec = BRIDGE[status]
	local entry = registered[character]
	if spec == nil or entry == nil or entry.effectsFolder == nil then
		return
	end
	local effects = entry.effectsFolder

	local ok, err = pcall(function()
		local found = effects:FindFirstChild(status)
		local reuse = found ~= nil and found:IsA(spec.className) and not spec.alwaysRecreate
		local instance: Instance

		if reuse then
			instance = found :: Instance
		else
			if found then
				-- Mark this as our own destroy so the ChildRemoved bridge doesn't treat it as the status ending.
				entry.selfDestroying[status] = (entry.selfDestroying[status] or 0) + 1
				found:Destroy()
			end
			instance = Instance.new(spec.className)
			instance.Name = status
		end

		-- Value and the attacker child are set before a fresh marker is parented, so
		-- ChildAdded readers never see a stale/default Value.
		local value = spec.value(info.data, info.duration)
		if value ~= nil then
			(instance :: any).Value = value
		end

		-- Knocked parents a StringValue named after the attacker under the marker.
		if status == "Knocked" and type(info.data) == "table" and type(info.data.by) == "string" then
			local byName = info.data.by :: string
			if instance:FindFirstChild(byName) == nil then
				local marker = Instance.new("StringValue")
				marker.Name = byName
				marker.Parent = instance
			end
		end

		if not reuse then
			instance.Parent = effects
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
			entry.selfDestroying[status] = (entry.selfDestroying[status] or 0) + 1
			instance:Destroy()
		end
	end)
	if not ok then
		log:Warn(string.format("couldn't remove %s's %s bridge marker: %s", character.Name, status, tostring(err)))
	end
end

-- Every mirrored attribute is a plain boolean EXCEPT Bleed, whose attribute is its
-- current stack count (0 once inactive). `info` carries that count on Apply (and every
-- refreshing re-Apply, since Changed doesn't re-fire); Remove has no info to give,
-- since inactive always means 0.
local function mirrorAttribute(character: Model, status: string, active: boolean, info: StatusInfo?)
	local attrName = ATTRIBUTE_FOR[status]
	if attrName == nil then
		return
	end
	local value: any = active
	if status == "Bleed" then
		value = if active and info and type(info.data) == "table" then (info.data :: any).stacks or 0 else 0
	end
	pcall(function()
		character:SetAttribute(attrName, value)
	end)
end


-- Assigned once StatusService.Remove is defined; declared here so earlier helpers (the
-- ChildRemoved bridge, removeAllStatuses) can call it.
local RemoveImpl: (character: Model, status: string) -> ()


local function backfillMarkers(character: Model, entry: RegisteredEntry)
	for status, info in entry.statuses do
		writeBridgeMarker(character, status, info)
	end
end

local function watchEffectsRemoved(character: Model, entry: RegisteredEntry)
	if entry.effectsFolder == nil or entry.effectsRemovedConn ~= nil then
		return
	end
	entry.effectsRemovedConn = (entry.effectsFolder :: Folder).ChildRemoved:Connect(function(child: Instance)
		local status = child.Name
		local pending = entry.selfDestroying[status]
		if pending and pending > 0 then
			entry.selfDestroying[status] = pending - 1
			return
		end
		if BRIDGE[status] ~= nil and entry.statuses[status] ~= nil then
			RemoveImpl(character, status)
		end
	end)
end

-- Never yields the caller. A brand-new player's `Effects` can take many seconds to be
-- created by EffectsService (it waits on AppearenceLoaded); creating our own first would
-- make EffectsService add a SECOND folder that its hooks connect to. So for a player
-- (owner ~= nil) keep waiting and never create one, giving up only if the character
-- leaves. An NPC (owner == nil) has no EffectsService pipeline, so it gets a bounded
-- wait and a fallback create.
local function resolveEffectsFolder(character: Model, entry: RegisteredEntry)
	local existing = character:FindFirstChild("Effects")
	if existing and existing:IsA("Folder") then
		entry.effectsFolder = existing
		watchEffectsRemoved(character, entry)
		backfillMarkers(character, entry)
		return
	end

	task.spawn(function()
		if entry.owner ~= nil then
			while registered[character] == entry and character.Parent ~= nil do
				local waited = character:WaitForChild("Effects", EFFECTS_RETRY)
				if registered[character] ~= entry then
					return
				end
				if waited and waited:IsA("Folder") then
					entry.effectsFolder = waited
					watchEffectsRemoved(character, entry)
					backfillMarkers(character, entry)
					return
				end
			end
			return
		end

		-- NPC path: bounded wait, then create it ourselves if still missing.
		local waited = character:WaitForChild("Effects", NPC_EFFECTS_WAIT_TIMEOUT)
		if registered[character] ~= entry then
			return
		end
		if waited and waited:IsA("Folder") then
			entry.effectsFolder = waited
		elseif character.Parent ~= nil then
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
				return
			end
		else
			return
		end
		watchEffectsRemoved(character, entry)
		backfillMarkers(character, entry)
	end)
end


local function removeAllStatuses(character: Model, entry: RegisteredEntry)
	local names: { string } = {}
	for status in entry.statuses do
		table.insert(names, status)
	end
	for _, status in names do
		RemoveImpl(character, status)
	end
end

function StatusService.Register(character: Model, owner: Player?)
	local existing = registered[character]
	if existing then
		existing.owner = owner
		return
	end

	local entry: RegisteredEntry = { owner = owner, statuses = {}, selfDestroying = {} }
	registered[character] = entry

	local okAncestry, conn = pcall(function()
		return character.AncestryChanged:Connect(function(_child, parent)
			if parent == nil then
				StatusService.Unregister(character)
			end
		end)
	end)
	if okAncestry then
		entry.ancestryConn = conn
	end

	-- Statuses shouldn't outlive the combatant's death.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local okDied, diedConn = pcall(function()
			return humanoid.Died:Connect(function()
				removeAllStatuses(character, entry)
			end)
		end)
		if okDied then
			entry.humanoidDiedConn = diedConn
		end
	end

	resolveEffectsFolder(character, entry)
end

function StatusService.IsRegistered(character: Model): boolean
	return registered[character] ~= nil
end

-- Safe on a character that's already gone: every write is guarded and a missing entry
-- is a no-op. Every active status goes through the real Remove (marker cleared, Changed
-- fired), not just an attribute clear.
function StatusService.Unregister(character: Model)
	local entry = registered[character]
	if entry == nil then
		return
	end

	removeAllStatuses(character, entry)
	registered[character] = nil

	if entry.ancestryConn then
		entry.ancestryConn:Disconnect()
	end
	if entry.effectsRemovedConn then
		entry.effectsRemovedConn:Disconnect()
	end
	if entry.humanoidDiedConn then
		entry.humanoidDiedConn:Disconnect()
	end
end


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
		parryFlipAt = nil,
	}

	-- Schedule Block's own 1 -> 0 parry-window flip here so a caller never re-Applies.
	if status == "Block" then
		local blockValue = if type(data) == "table" and data.value ~= nil then data.value else 1
		if blockValue == 1 then
			info.parryFlipAt = os.clock() + Combat.Block.parryWindow
		end
	end

	entry.statuses[status] = info

	writeBridgeMarker(character, status, info)
	mirrorAttribute(character, status, true, info)

	if not wasActive then
		changedBindable:Fire(character, status, true)
	end
end

-- Safe on a character that's already gone: a missing entry or inactive status is a no-op.
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

RemoveImpl = StatusService.Remove

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
	-- One shared loop for every combatant's status durations (players and NPCs): no
	-- per-status task.delay, so nothing leaks on respawn or death. Also flips Block's
	-- parry window.
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
					elseif status == "Block" and info.parryFlipAt and now >= info.parryFlipAt then
						info.parryFlipAt = nil
						info.data = { value = 0 }
						writeBridgeMarker(character, status, info)
					end
				end
			end
		end
	end)
end

return StatusService
