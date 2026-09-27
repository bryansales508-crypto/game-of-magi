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
-- (EffectsService still does, reacting to the same markers as before). The
-- bridge is two-way (REVIEW-M3-01 M2): if a marker disappears by some
-- other script's own hand (old code still destroys a few of these itself),
-- StatusService treats that as the status ending too.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Log = require(ReplicatedStorage.Shared.Log)
local Combat = require(ReplicatedStorage.Shared.Data.Combat)
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
	-- Block only (REVIEW-M3-01 L4): os.clock() the parry window (value 1)
	-- flips to the block hold (value 0) at, or nil once it's already
	-- flipped (or was never scheduled).
	parryFlipAt: number?,
}

type RegisteredEntry = {
	owner: Player?,
	statuses: { [string]: StatusInfo },
	effectsFolder: Folder?,
	ancestryConn: RBXScriptConnection?,
	effectsRemovedConn: RBXScriptConnection?,
	humanoidDiedConn: RBXScriptConnection?,
	-- Name -> in-flight self-Destroy() count, so the Effects.ChildRemoved
	-- bridge below (M2) can tell "we just destroyed our own marker" apart
	-- from "something else destroyed it" without misfiring under deferred
	-- signal behavior (REVIEW-M3-01 M2).
	selfDestroying: { [string]: number },
}

local TICK = 0.1
local EFFECTS_RETRY = 1
local NPC_EFFECTS_WAIT_TIMEOUT = 5

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
-- scripts too). alwaysRecreate (REVIEW-M3-01 M1): the old code always
-- added a brand-new Instance per hit, and several readers (EffectsService's
-- sound/particle, FaceControl's hurt face, PhysicalHandler's stagger, the
-- FragilePackage mission) key off ChildAdded - reusing one Hit marker
-- across repeated hits would go silent after the first.

type BridgeSpec = {
	className: "StringValue" | "IntValue",
	value: (data: any?, duration: number?) -> any?,
	alwaysRecreate: boolean?,
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
		alwaysRecreate = true,
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
	-- StatusService itself flips this 1 -> 0 after Combat.Block.parryWindow
	-- on the shared loop (REVIEW-M3-01 L4); a caller (CombatService, M3-03)
	-- just Applies once with {value = 1} (or no data at all: 1 is the
	-- default, matching the old remote's own Block(true)) and never has to
	-- re-Apply to flip it itself.
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

-- ==================== bridge writes ====================
-- Defined before the Effects-folder resolution below, which backfills
-- through this same function (REVIEW-M3-01 L2).

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
				-- REVIEW-M3-01 M2: mark this as our own destroy so the
				-- ChildRemoved bridge below doesn't treat it as the status
				-- ending.
				entry.selfDestroying[status] = (entry.selfDestroying[status] or 0) + 1
				found:Destroy()
			end
			instance = Instance.new(spec.className)
			instance.Name = status
		end

		-- REVIEW-M3-01 L3: Value and the attacker child are set before a
		-- freshly-created marker is parented, so anything reacting to
		-- ChildAdded (or the old code's Immediate-signal readers) never
		-- sees a marker with a stale/default Value.
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

local function mirrorAttribute(character: Model, status: string, active: boolean)
	local attrName = ATTRIBUTE_FOR[status]
	if attrName == nil then
		return
	end
	pcall(function()
		character:SetAttribute(attrName, active)
	end)
end

-- ==================== public API (forward-declared for the folder/removed-bridge helpers) ====================

-- Assigned right after StatusService.Remove is defined further down;
-- declared here so resolveEffectsFolder's ChildRemoved bridge and
-- removeAllStatuses (both defined before the public API section for
-- readability) can call it.
local RemoveImpl: (character: Model, status: string) -> ()

-- ==================== effects folder (bridge home) ====================

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

-- Never yields the caller. REVIEW-M3-01 H1: a brand-new player's character
-- can go many seconds before EffectsService gets around to creating
-- `Effects` (it waits on AppearenceLoaded); if StatusService raced ahead
-- and made its own folder first, EffectsService would later add a SECOND
-- one that its own ragdoll/sound/TrueStun hooks are connected to, while
-- everyone else keeps writing into ours. So: for a player (owner ~= nil),
-- keep waiting - however long it takes - and never create one ourselves;
-- only give up if the character leaves first. Only an NPC (owner == nil,
-- no EffectsService pipeline ever creates one for it) gets a bounded wait
-- and a fallback create.
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

-- ==================== register / unregister ====================

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

	-- REVIEW-M3-01 L1: statuses shouldn't outlive the combatant's death
	-- (they'd otherwise keep running until the corpse is actually removed).
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

-- Safe to call on a character that's already gone (AUDIT M18): every write
-- below is guarded, and a missing entry is just a no-op. REVIEW-M3-01 M3:
-- every active status goes through the real Remove (bridge marker cleared,
-- Changed fired), not just a direct attribute clear.
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
		parryFlipAt = nil,
	}

	-- REVIEW-M3-01 L4: schedule Block's own 1 -> 0 parry-window flip here,
	-- so a caller never has to re-Apply just to end the parry window.
	if status == "Block" then
		local blockValue = if type(data) == "table" and data.value ~= nil then data.value else 1
		if blockValue == 1 then
			info.parryFlipAt = os.clock() + Combat.Block.parryWindow
		end
	end

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
	-- wider "no leaked listeners or threads" rule for M3). Also flips
	-- Block's parry window (REVIEW-M3-01 L4).
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
