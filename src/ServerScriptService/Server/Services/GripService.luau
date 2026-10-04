--!strict
-- Gripping: a gripper chokes a knocked-out player for Config.Bounty.Grip.Seconds and, if nothing
-- interrupts them, the victim dies (an ordinary death: costs a life, the last life runs the scene).
-- The server decides everything; the client only asks (GripStart / GripStop) and shows GripState.
--
-- The gripper may be a Player or an NPC Model (a Target dummy). Both are combatants keyed by
-- character in StatusService, so the same statuses work for either: the gripper gets `Gripping`
-- (walk speed 0 through a MovementService modifier; run/dash/attack/block refused through the
-- BLOCKS_* tables), the victim gets `Gripped` and has their Knocked status refreshed every tick,
-- exactly like CarryService, so they cannot get up. Progress is server-timed and published on the
-- victim's `GripProgress` attribute (0..1) and the gripper's `GrippingTarget` attribute (name).
--
-- A grip ends without a kill (Stop) when: the gripper is hit, knocked, stunned or jailed; either side
-- dies, leaves or respawns; the gripper is pushed more than BreakDistance from where they began;
-- the client sends GripStop; the victim stops being Knocked, or is picked up or jailed. The victim
-- then stays Knocked GraceSeconds longer. Completing pays the gripper (players only): Black Rukh
-- for every grip, plus the bounty (Copper, Magoi, Black Rukh) when the victim is wanted and the
-- gripper holds their poster. No bounty is ever added to the gripper.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Config = require(ReplicatedStorage.Shared.Config)
local Combat = require(ReplicatedStorage.Shared.Data.Combat)
local StatusService = require(script.Parent.StatusService)
local MovementService = require(script.Parent.MovementService)
local CombatService = require(script.Parent.CombatService)
local BountyData = require(ReplicatedStorage.Shared.Data.Bounty)
local BountyService = require(script.Parent.BountyService)
local RankService = require(script.Parent.RankService)
local DevService = require(script.Parent.DevService)

local log = Log.new("GripService")

-- A real Player, a self-test stand-in table with Name/UserId/Character, or an NPC's Model.
export type Gripper = Player | Model

type Grip = {
	gripper: Gripper,
	-- The player behind the gripper; nil for an NPC (no poster, no reward).
	gripperPlayer: Player?,
	victim: Player,
	-- The models the grip was made with. Ending acts on these, never on Player.Character, which may
	-- already be a replacement by then.
	gripperModel: Model,
	victimModel: Model,
	startPosition: Vector3,
	startedAt: number,
	connections: { RBXScriptConnection },
}

-- A start decision's inputs, gathered by Begin and fed to Decide.
export type StartFacts = {
	sameBody: boolean,
	victimKnocked: boolean,
	-- The first blocking status on each side, or nil.
	gripperBlockedBy: string?,
	victimBlockedBy: string?,
	distance: number?, -- nil when a root part is missing
}

local GRIPPER_BLOCKERS = { "Knocked", "Stun", "TrueStun", "Jailed", "Carrying", "Carried", "Gripping", "Gripped" }
local VICTIM_BLOCKERS = { "Carried", "Jailed", "Gripped" }
-- A status turning on for the gripper that ends the grip.
local ENDS_FOR_GRIPPER: { [string]: boolean } = { Knocked = true, Stun = true, TrueStun = true, Jailed = true, Carried = true, Carrying = true }
-- A status turning on for the victim that ends the grip (Knocked turning off does too).
local ENDS_FOR_VICTIM: { [string]: boolean } = { Carried = true, Jailed = true }

local GripService = {}

-- What completing a grip pays through. Production wires these to BountyService and RankService;
-- the self-test swaps in recorders (it has no saves for stand-in players).
GripService.Rewards = {
	settle = function(victim: Player, gripper: Player): BountyData.Reward?
		return BountyService.SettleByGrip(victim, gripper)
	end,
	blackDeed = function(gripper: Player, amount: number)
		RankService.AddDeed(gripper, "Black", amount)
	end,
}

local byGripper: { [Gripper]: Grip } = {}
local byVictim: { [Player]: Grip } = {}

-- ==================== pure core ====================

-- Pure: whether a grip may start. Returns (true) or (false, reason for the log).
function GripService.Decide(facts: StartFacts): (boolean, string?)
	if facts.sameBody then
		return false, "cannot grip yourself"
	end
	if not facts.victimKnocked then
		return false, "victim is not knocked out"
	end
	if facts.gripperBlockedBy then
		return false, "gripper is " .. facts.gripperBlockedBy
	end
	if facts.victimBlockedBy then
		return false, "victim is " .. facts.victimBlockedBy
	end
	if facts.distance == nil or facts.distance > Config.Bounty.Grip.ReachStuds then
		return false, "victim out of reach"
	end
	return true, nil
end

-- Pure: how far a grip is, 0..1.
function GripService.Progress(startedAt: number, now: number): number
	return math.clamp((now - startedAt) / Config.Bounty.Grip.Seconds, 0, 1)
end

-- ==================== helpers ====================

local function isModel(gripper: Gripper): boolean
	return typeof(gripper) == "Instance" and (gripper :: Instance):IsA("Model")
end

local function characterOf(gripper: Gripper): Model?
	if isModel(gripper) then
		return gripper :: Model
	end
	return (gripper :: Player).Character
end

local function nameOf(gripper: Gripper): string
	if isModel(gripper) then
		return (gripper :: Model).Name
	end
	return (gripper :: Player).Name
end

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

local function isAlive(character: Model?): boolean
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

-- A player in the age-death scene (heart attack) is past gripping, and past being gripped.
local function isDying(gripper: Gripper): boolean
	return typeof(gripper) == "Instance" and not isModel(gripper) and (gripper :: Player):GetAttribute("Dying") == true
end

local function identity(gripper: Gripper): { userId: number, name: string }
	if isModel(gripper) then
		return { userId = 0, name = (gripper :: Model).Name }
	end
	local player = gripper :: Player
	return { userId = player.UserId, name = player.Name }
end

-- Only real Players have a client to tell (self-tests use stand-ins).
local function send(player: Player, payload: { [string]: any })
	if typeof(player) == "Instance" then
		Remotes.Server.Fire("GripState", player, payload)
	end
end

local function sendBoth(grip: Grip, progress: number, reason: string?)
	local ended = reason ~= nil
	if not isModel(grip.gripper) then
		send(grip.gripper :: Player, {
			gripping = if ended then nil else identity(grip.victim),
			grippedBy = nil,
			progress = progress,
			reason = reason,
		})
	end
	send(grip.victim, {
		gripping = nil,
		grippedBy = if ended then nil else identity(grip.gripper),
		progress = progress,
		reason = reason,
	})
end

local function setAttribute(instance: Instance, name: string, value: any)
	pcall(function()
		instance:SetAttribute(name, value)
	end)
end

-- ==================== queries ====================

function GripService.IsGripping(gripper: Gripper): boolean
	return byGripper[gripper] ~= nil
end

function GripService.GetVictim(gripper: Gripper): Player?
	local grip = byGripper[gripper]
	return if grip then grip.victim else nil
end

function GripService.IsGripped(victim: Player): boolean
	return byVictim[victim] ~= nil
end

-- ==================== ending ====================

-- Tears the grip down. `grace`: the victim stays Knocked a little longer (a broken grip).
local function endGrip(grip: Grip, reason: string, grace: boolean)
	byGripper[grip.gripper] = nil
	byVictim[grip.victim] = nil
	for _, connection in grip.connections do
		connection:Disconnect()
	end
	table.clear(grip.connections)

	StatusService.Remove(grip.gripperModel, "Gripping")
	MovementService.ClearModifier(grip.gripperModel, "Gripping")
	StatusService.Remove(grip.victimModel, "Gripped")
	setAttribute(grip.gripperModel, "GrippingTarget", nil)
	setAttribute(grip.victimModel, "GripProgress", nil)

	-- A grip that is broken is not a free escape; only a body that is still the player's own gets it.
	local victimCurrent = grip.victim.Character == grip.victimModel and grip.victimModel.Parent ~= nil
	local knocked = StatusService.Get(grip.victimModel, "Knocked")
	if grace and victimCurrent and knocked and isAlive(grip.victimModel) then
		StatusService.Apply(grip.victimModel, "Knocked", Config.Bounty.Grip.GraceSeconds, knocked.data)
	end

	sendBoth(grip, 0, reason)
end

-- Ends `gripper`'s grip with no kill. Returns whether there was one.
function GripService.Stop(gripper: Gripper, reason: string): boolean
	local grip = byGripper[gripper]
	if grip == nil then
		return false
	end
	endGrip(grip, reason, true)
	log:Info(string.format("%s's grip on %s broke (%s)", nameOf(grip.gripper), grip.victim.Name, reason))
	return true
end

-- The timer ran out: the victim dies, the gripper is paid.
local function complete(grip: Grip)
	endGrip(grip, "completed", false)

	local gripperName = nameOf(grip.gripper)
	local victimName = grip.victim.Name
	local gripperPlayer = grip.gripperPlayer

	-- The kill comes first, so a failing reward can never spare the victim. An ordinary death:
	-- LifeService charges the life from Humanoid.Died (deferred, so the saves are still there for
	-- the payout below).
	setAttribute(grip.victimModel, "DeathCause", "gripped by " .. gripperName)
	local humanoid = grip.victimModel:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Health = 0
	end

	local paidBounty = false
	if gripperPlayer then
		local ok, err = pcall(function()
			paidBounty = GripService.Rewards.settle(grip.victim, gripperPlayer) ~= nil
			GripService.Rewards.blackDeed(gripperPlayer, Config.Bounty.Grip.BlackRukh)
		end)
		if not ok then
			log:Error(string.format("reward for %s gripping %s failed: %s", gripperName, victimName, tostring(err)))
		end
	end
	log:Info(string.format("%s gripped %s to death%s", gripperName, victimName, if paidBounty then " (bounty collected)" else ""))
end

-- ==================== begin ====================

-- (Named Begin, not Start: Start is the service lifecycle hook.)

-- Starts `gripper` gripping `victim` (a Player or a UserId). Returns (true) or (false, reason).
function GripService.Begin(gripper: Gripper, victimRef: Player | number): (boolean, string?)
	local victim: Player? = if type(victimRef) == "number" then Players:GetPlayerByUserId(victimRef) else victimRef :: Player
	if victim == nil then
		return false, "victim not found"
	end
	local gripperModel = characterOf(gripper)
	local victimModel = victim.Character
	if gripperModel == nil or victimModel == nil or not isAlive(gripperModel) or not isAlive(victimModel) then
		return false, "a character is missing or dead"
	end
	if byGripper[gripper] ~= nil then
		return false, "already gripping"
	end
	if isDying(gripper) or isDying(victim) then
		return false, "a party is in the death scene"
	end
	local gripperRoot = rootOf(gripperModel)
	local victimRoot = rootOf(victimModel)

	local ok, reason = GripService.Decide({
		sameBody = gripperModel == victimModel,
		victimKnocked = StatusService.Has(victimModel, "Knocked"),
		gripperBlockedBy = firstStatus(gripperModel, GRIPPER_BLOCKERS),
		victimBlockedBy = firstStatus(victimModel, VICTIM_BLOCKERS),
		distance = if gripperRoot and victimRoot then (gripperRoot.Position - victimRoot.Position).Magnitude else nil,
	})
	if not ok or gripperRoot == nil then
		log:Info(string.format("%s cannot grip %s: %s", nameOf(gripper), victim.Name, reason or "no root part"))
		return false, reason
	end

	local grip: Grip = {
		gripper = gripper,
		gripperPlayer = if isModel(gripper) then nil else gripper :: Player,
		victim = victim,
		gripperModel = gripperModel,
		victimModel = victimModel,
		startPosition = gripperRoot.Position,
		startedAt = os.clock(),
		connections = {},
	}
	byGripper[gripper] = grip
	byVictim[victim] = grip

	StatusService.Apply(gripperModel, "Gripping", nil, { victimUserId = victim.UserId })
	StatusService.Apply(victimModel, "Gripped", nil, { gripperUserId = identity(gripper).userId, gripperName = nameOf(gripper) })
	-- The knockout cannot run out while gripped, even one grabbed in its last moments.
	local knocked = StatusService.Get(victimModel, "Knocked")
	StatusService.Apply(victimModel, "Knocked", Combat.Knockout.getUpSeconds, if knocked then knocked.data else nil)
	MovementService.SetRunning(gripperModel, false)
	MovementService.SetModifier(gripperModel, "Gripping", 0)
	setAttribute(gripperModel, "GrippingTarget", victim.Name)
	setAttribute(victimModel, "GripProgress", 0)

	local function endIt(why: string)
		task.defer(function()
			-- Only this grip: a newer one by the same gripper is not ours to end.
			if byGripper[gripper] == grip then
				GripService.Stop(gripper, why)
			end
		end)
	end
	for _, character in { gripperModel, victimModel } do
		table.insert(
			grip.connections,
			character.AncestryChanged:Connect(function(_child, parent)
				if parent == nil then
					endIt("character removed")
				end
			end)
		)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			table.insert(
				grip.connections,
				humanoid.Died:Connect(function()
					endIt("died")
				end)
			)
		end
	end

	sendBoth(grip, 0, nil)
	log:Info(string.format("%s began gripping %s", nameOf(gripper), victim.Name))
	return true, nil
end

-- ==================== loop ====================

-- One server tick: checks every grip is still valid, keeps victims down, publishes progress and
-- completes the ones whose time is up. `now` is injectable for the self-test.
function GripService.Tick(now: number?)
	local clock = now or os.clock()
	local grips: { Grip } = {}
	for _, grip in byGripper do
		table.insert(grips, grip)
	end

	for _, grip in grips do
		if byGripper[grip.gripper] ~= grip then
			continue
		end
		local gripperCurrent = characterOf(grip.gripper) == grip.gripperModel and grip.gripperModel.Parent ~= nil
		local victimCurrent = grip.victim.Character == grip.victimModel and grip.victimModel.Parent ~= nil
		if not gripperCurrent or not victimCurrent or not isAlive(grip.gripperModel) or not isAlive(grip.victimModel) then
			GripService.Stop(grip.gripper, "a party is gone")
			continue
		end
		if isDying(grip.gripper) or isDying(grip.victim) then
			GripService.Stop(grip.gripper, "death scene")
			continue
		end
		local knocked = StatusService.Get(grip.victimModel, "Knocked")
		if knocked == nil then
			GripService.Stop(grip.gripper, "victim no longer knocked out")
			continue
		end
		local root = rootOf(grip.gripperModel)
		if root == nil or (root.Position - grip.startPosition).Magnitude > Config.Bounty.Grip.BreakDistance then
			GripService.Stop(grip.gripper, "moved away")
			continue
		end

		StatusService.Apply(grip.victimModel, "Knocked", Combat.Knockout.getUpSeconds, knocked.data)
		local progress = GripService.Progress(grip.startedAt, clock)
		if progress >= 1 then
			complete(grip)
			continue
		end
		setAttribute(grip.victimModel, "GripProgress", progress)
		sendBoth(grip, progress, nil)
	end
end

-- ==================== lifecycle ====================

local function onStatusChanged(character: Model, status: string, active: boolean)
	for gripper, grip in byGripper do
		if grip.gripperModel == character and active and ENDS_FOR_GRIPPER[status] then
			GripService.Stop(gripper, "gripper " .. string.lower(status))
			return
		elseif grip.victimModel == character then
			if (active and ENDS_FOR_VICTIM[status]) or (not active and status == "Knocked") then
				GripService.Stop(gripper, "victim " .. string.lower(status))
			end
			return
		end
	end
end

-- Any hit that lands on a gripper breaks the grip.
local function onHitLanded(target: Model, _attacker: Model, _hitName: string)
	for gripper, grip in byGripper do
		if grip.gripperModel == target then
			GripService.Stop(gripper, "hit")
			return
		end
	end
end

function GripService:Init()
	DevService.Register("grip", "<player> | stop - grip a knocked-out player in reach (kills them in a few seconds)", function(caller: Player, args: { string }): string
		if args[1] == "stop" then
			return if GripService.Stop(caller, "dev command") then "grip stopped" else "you are not gripping"
		end
		local target, err = DevService.ResolvePlayer(caller, args[1])
		if target == nil then
			return err or "player not found"
		end
		local ok, reason = GripService.Begin(caller, target)
		return if ok then string.format("gripping %s", target.Name) else (reason or "refused")
	end)
end

function GripService:Start()
	Remotes.Server.On("GripStart", function(player: Player, userId: number)
		GripService.Begin(player, userId)
	end)
	Remotes.Server.On("GripStop", function(player: Player)
		GripService.Stop(player, "released")
	end)

	StatusService.Changed:Connect(onStatusChanged)
	CombatService.HitLanded:Connect(onHitLanded)

	Players.PlayerRemoving:Connect(function(player: Player)
		local asVictim = byVictim[player]
		if asVictim then
			GripService.Stop(asVictim.gripper, "victim left")
		end
		GripService.Stop(player, "gripper left")
	end)

	task.spawn(function()
		while true do
			task.wait(Config.Bounty.Grip.TickSeconds)
			local ok, err = pcall(function()
				GripService.Tick()
			end)
			if not ok then
				log:Error(string.format("grip tick errored: %s", tostring(err)))
			end
		end
	end)
end

return GripService
