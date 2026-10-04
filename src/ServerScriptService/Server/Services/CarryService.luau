--!strict
-- Carrying a knocked-out player over the shoulder. The server decides everything: the client
-- only asks (CarryPickUp / CarryDrop). A carried player is welded to the carrier's torso at
-- Config.Bounty.Carry.Offset, keeps the ragdoll their Knocked status built, and has their
-- Knocked status refreshed every RefreshSeconds so the get-up timer never fires while carried;
-- GraceSeconds of Knocked follow a drop. The carrier walks at SpeedMult and the Carrying status
-- blocks run, dash, attack and block (Movement/CombatService tables).
--
-- A carry ends when: the carrier drops, is knocked out, dies, respawns or leaves; or the target
-- dies, respawns or leaves. A refusal is silent for the client and logged.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Config = require(ReplicatedStorage.Shared.Config)
local Combat = require(ReplicatedStorage.Shared.Data.Combat)
local StatusService = require(script.Parent.StatusService)
local MovementService = require(script.Parent.MovementService)
local DevService = require(script.Parent.DevService)

local log = Log.new("CarryService")

type Carry = {
	carrier: Player,
	target: Player,
	-- The models the carry was made with. Drop acts on these, never on Player.Character, which may
	-- already be a replacement (a LoadCharacter) by the time a drop runs.
	carrierCharacter: Model,
	targetCharacter: Model,
	weld: WeldConstraint,
	-- CanCollide each target part had before the carry turned it off.
	collide: { [BasePart]: boolean },
	connections: { RBXScriptConnection },
	-- What the carrier was last told about delivering, so a change is re-sent.
	canDeliver: boolean,
}

-- A pick-up decision's inputs, gathered by PickUp and fed to Decide.
export type PickUpFacts = {
	sameCharacter: boolean,
	targetKnocked: boolean,
	-- The first blocking status on each side, or nil.
	carrierBlockedBy: string?,
	targetBlockedBy: string?,
	distance: number?, -- nil when a root part is missing
}

local CARRIER_BLOCKERS = { "Knocked", "Stun", "TrueStun", "Jailed", "Carrying", "Carried", "Gripping" }
local TARGET_BLOCKERS = { "Jailed", "Carrying", "Carried" }

local CarryService = {}

-- Asked, for the carrier's CarryState, whether they could hand this target to a jail right now and where the dropoff is (`canDeliver`, `dropoffPath`). JailService provides it; nil means no jail.
local deliveryInfo: ((carrier: Player, target: Player) -> (boolean, string?))? = nil

function CarryService.SetDeliveryInfo(provider: (carrier: Player, target: Player) -> (boolean, string?))
	deliveryInfo = provider
end

local byCarrier: { [Player]: Carry } = {}
local byTarget: { [Player]: Carry } = {}

-- ==================== pure core ====================

-- Pure: whether a pick-up is allowed. Returns (true) or (false, reason for the log).
function CarryService.Decide(facts: PickUpFacts): (boolean, string?)
	if facts.sameCharacter then
		return false, "cannot carry yourself"
	end
	if not facts.targetKnocked then
		return false, "target is not knocked out"
	end
	if facts.carrierBlockedBy then
		return false, "carrier is " .. facts.carrierBlockedBy
	end
	if facts.targetBlockedBy then
		return false, "target is " .. facts.targetBlockedBy
	end
	if facts.distance == nil or facts.distance > Config.Bounty.Carry.ReachStuds then
		return false, "target out of reach"
	end
	return true, nil
end

-- ==================== helpers ====================

local function firstStatus(character: Model, names: { string }): string?
	for _, name in names do
		if StatusService.Has(character, name) then
			return name
		end
	end
	return nil
end

local function rootOf(character: Model?): BasePart?
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function torsoOf(character: Model): BasePart?
	for _, name in { "UpperTorso", "Torso", "HumanoidRootPart" } do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end
	return nil
end

local function isAlive(character: Model?): boolean
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function identity(player: Player): { userId: number, name: string }
	return { userId = player.UserId, name = player.Name }
end

-- Only real Players have a client to tell (self-tests use stand-ins).
local function send(player: Player, payload: { [string]: any })
	if typeof(player) == "Instance" then
		Remotes.Server.Fire("CarryState", player, payload)
	end
end

-- ==================== queries ====================

function CarryService.GetCarried(carrier: Player): Player?
	local carry = byCarrier[carrier]
	return if carry then carry.target else nil
end

function CarryService.IsCarrying(carrier: Player): boolean
	return byCarrier[carrier] ~= nil
end

function CarryService.IsCarried(target: Player): boolean
	return byTarget[target] ~= nil
end

-- ==================== drop ====================

-- Ends `carrier`'s carry. The target is put at `placeAt`, else just in front of the carrier.
-- Returns whether there was a carry.
function CarryService.Drop(carrier: Player, reason: string, placeAt: CFrame?): boolean
	local carry = byCarrier[carrier]
	if carry == nil then
		return false
	end
	byCarrier[carrier] = nil
	byTarget[carry.target] = nil

	for _, connection in carry.connections do
		connection:Disconnect()
	end
	carry.weld:Destroy()

	local carrierCharacter = carry.carrierCharacter
	local targetCharacter = carry.targetCharacter
	local targetRoot = rootOf(targetCharacter)

	for part, canCollide in carry.collide do
		if part.Parent then
			part.CanCollide = canCollide
		end
	end

	-- Only a body that is still the player's current one is moved or given grace.
	local targetCurrent = carry.target.Character == targetCharacter and targetCharacter.Parent ~= nil
	local carrierCurrent = carrier.Character == carrierCharacter and carrierCharacter.Parent ~= nil

	if targetCurrent and targetRoot then
		local carrierRoot = if carrierCurrent then rootOf(carrierCharacter) else nil
		if placeAt then
			targetCharacter:PivotTo(placeAt)
		elseif carrierRoot then
			local front = carrierRoot.Position + carrierRoot.CFrame.LookVector * Config.Bounty.Carry.DropDistance
			targetCharacter:PivotTo(CFrame.new(front) * carrierRoot.CFrame.Rotation)
		end
	end
	-- The body is the target's own again.
	if targetRoot and typeof(carry.target) == "Instance" and not targetRoot.Anchored then
		pcall(function()
			targetRoot:SetNetworkOwner(carry.target)
		end)
	end

	StatusService.Remove(carrierCharacter, "Carrying")
	MovementService.ClearModifier(carrierCharacter, "Carrying")
	StatusService.Remove(targetCharacter, "Carried")
	-- A drop is not a free escape: they stay down a little longer.
	local knocked = StatusService.Get(targetCharacter, "Knocked")
	if targetCurrent and knocked and isAlive(targetCharacter) then
		StatusService.Apply(targetCharacter, "Knocked", Config.Bounty.Carry.GraceSeconds, knocked.data)
	end

	send(carrier, { carrying = nil, carriedBy = nil, canDeliver = false, dropoffPath = nil })
	send(carry.target, { carrying = nil, carriedBy = nil, canDeliver = false, dropoffPath = nil })
	log:Info(string.format("%s dropped %s (%s)", carrier.Name, carry.target.Name, reason))
	return true
end

-- ==================== pick up ====================

function CarryService.PickUp(carrier: Player, target: Player): (boolean, string?)
	local carrierCharacter = carrier.Character
	local targetCharacter = target.Character
	if carrierCharacter == nil or targetCharacter == nil or not isAlive(carrierCharacter) or not isAlive(targetCharacter) then
		return false, "a character is missing or dead"
	end
	local carrierRoot = rootOf(carrierCharacter)
	local targetRoot = rootOf(targetCharacter)
	local torso = torsoOf(carrierCharacter)

	local ok, reason = CarryService.Decide({
		sameCharacter = carrier == target,
		targetKnocked = StatusService.Has(targetCharacter, "Knocked"),
		carrierBlockedBy = firstStatus(carrierCharacter, CARRIER_BLOCKERS),
		targetBlockedBy = firstStatus(targetCharacter, TARGET_BLOCKERS),
		distance = if carrierRoot and targetRoot then (carrierRoot.Position - targetRoot.Position).Magnitude else nil,
	})
	if not ok or carrierRoot == nil or targetRoot == nil or torso == nil then
		log:Info(string.format("%s cannot carry %s: %s", carrier.Name, target.Name, reason or "no torso"))
		return false, reason
	end

	-- Over the shoulder: ride at the offset, rolled so the body lies across it.
	local rules = Config.Bounty.Carry
	local ride = torso.CFrame * CFrame.new(rules.Offset) * CFrame.Angles(0, 0, math.rad(rules.TiltDegrees))
	targetCharacter:PivotTo(ride)

	local weld = Instance.new("WeldConstraint")
	weld.Name = "CarryWeld"
	weld.Part0 = torso
	weld.Part1 = targetRoot
	weld.Parent = targetRoot

	local collide: { [BasePart]: boolean } = {}
	for _, descendant in targetCharacter:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.CanCollide then
			collide[descendant] = true
			descendant.CanCollide = false
		end
	end

	if typeof(carrier) == "Instance" and not targetRoot.Anchored then
		pcall(function()
			targetRoot:SetNetworkOwner(carrier)
		end)
	end

	local carry: Carry = { carrier = carrier, target = target, carrierCharacter = carrierCharacter, targetCharacter = targetCharacter, weld = weld, collide = collide, connections = {}, canDeliver = false }
	byCarrier[carrier] = carry
	byTarget[target] = carry

	StatusService.Apply(carrierCharacter, "Carrying", nil, { targetUserId = target.UserId })
	StatusService.Apply(targetCharacter, "Carried", nil, { carrierUserId = carrier.UserId })
	-- The knockout cannot run out while carried, even one grabbed in its last moments.
	local knockedInfo = StatusService.Get(targetCharacter, "Knocked")
	StatusService.Apply(targetCharacter, "Knocked", Combat.Knockout.getUpSeconds, if knockedInfo then knockedInfo.data else nil)
	MovementService.SetRunning(carrierCharacter, false)
	MovementService.SetModifier(carrierCharacter, "Carrying", rules.SpeedMult)

	local function endCarry(why: string)
		task.defer(CarryService.Drop, carrier, why, nil)
	end
	for _, character in { carrierCharacter, targetCharacter } do
		table.insert(
			carry.connections,
			character.AncestryChanged:Connect(function(_child, parent)
				if parent == nil then
					endCarry("character removed")
				end
			end)
		)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			table.insert(
				carry.connections,
				humanoid.Died:Connect(function()
					endCarry("died")
				end)
			)
		end
	end

	local canDeliver, dropoffPath = false, nil :: string?
	if deliveryInfo then
		canDeliver, dropoffPath = deliveryInfo(carrier, target)
	end
	carry.canDeliver = canDeliver
	send(carrier, { carrying = identity(target), carriedBy = nil, canDeliver = canDeliver, dropoffPath = dropoffPath })
	send(target, { carrying = nil, carriedBy = identity(carrier), canDeliver = false, dropoffPath = nil })
	log:Info(string.format("%s picked up %s", carrier.Name, target.Name))
	return true, nil
end

-- ==================== lifecycle ====================

local function onStatusChanged(character: Model, status: string, active: boolean)
	if not active or status ~= "Knocked" then
		return
	end
	-- A carrier who is knocked out drops their burden.
	for carrier in byCarrier do
		if carrier.Character == character then
			CarryService.Drop(carrier, "carrier knocked out", nil)
			return
		end
	end
end

local function onRemote(player: Player, userId: number)
	local target = Players:GetPlayerByUserId(userId)
	if target == nil then
		return
	end
	CarryService.PickUp(player, target)
end

-- Keeps every carried player Knocked, with the status's own data (who knocked them out), and
-- tells a carrier whose delivery chance changed (bounty taken or dropped). Runs on a loop.
function CarryService.RefreshCarried()
	for carrier, carry in byCarrier do
		local targetCharacter = carry.target.Character
		if targetCharacter and StatusService.Has(targetCharacter, "Knocked") then
			local info = StatusService.Get(targetCharacter, "Knocked") :: StatusService.StatusInfo
			StatusService.Apply(targetCharacter, "Knocked", Combat.Knockout.getUpSeconds, info.data)
			if deliveryInfo then
				local canDeliver, dropoffPath = deliveryInfo(carrier, carry.target)
				if canDeliver ~= carry.canDeliver then
					carry.canDeliver = canDeliver
					send(carrier, { carrying = identity(carry.target), carriedBy = nil, canDeliver = canDeliver, dropoffPath = dropoffPath })
				end
			end
		elseif targetCharacter then
			-- Something ended the knockout (dev command); the carry cannot go on.
			CarryService.Drop(carrier, "target no longer knocked out", nil)
		end
	end
end

function CarryService:Init()
	DevService.Register("carry", "drop - put down whoever you carry", function(caller: Player, args: { string }): string
		if args[1] ~= "drop" then
			return "usage: .carry drop"
		end
		return if CarryService.Drop(caller, "dev command", nil) then "dropped" else "you carry nobody"
	end)
end

function CarryService:Start()
	Remotes.Server.On("CarryPickUp", onRemote)
	Remotes.Server.On("CarryDrop", function(player: Player)
		CarryService.Drop(player, "asked to", nil)
	end)

	StatusService.Changed:Connect(onStatusChanged)

	Players.PlayerRemoving:Connect(function(player: Player)
		local asTarget = byTarget[player]
		if asTarget then
			CarryService.Drop(asTarget.carrier, "target left", nil)
		end
		CarryService.Drop(player, "carrier left", nil)
	end)

	task.spawn(function()
		while true do
			task.wait(Config.Bounty.Carry.RefreshSeconds)
			CarryService.RefreshCarried()
		end
	end)
end

return CarryService
