--!strict
-- The Dummy and Target behavior trees. Built fresh per NPC (BuildDummy()/BuildTarget()
-- are factories, not singletons) so Cooldown/Wait timers never leak between NPCs. Every
-- Condition/Action reads/writes an AiController.Blackboard passed in as `blackboard: any`;
-- this module doesn't require AiController back (a cyclic require).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")

local Log = require(ReplicatedStorage.Shared.Log)
local Config = require(ReplicatedStorage.Shared.Config)
local BehaviorTree = require(ReplicatedStorage.Shared.BehaviorTree)
local StatusService = require(script.Parent.Parent.StatusService)
local CombatService = require(script.Parent.Parent.CombatService)
local MovementService = require(script.Parent.Parent.MovementService)
local GripService = require(script.Parent.Parent.GripService)

local log = Log.new("NpcService")

local Trees = {}


local function isKnocked(bb: any): boolean
	return StatusService.Has(bb.character, "Knocked")
end

-- Every landed hit applies LightStun (nothing applies "Hit"), so that is the "I was just hit" signal.
local function wasHit(bb: any): boolean
	return StatusService.Has(bb.character, "LightStun")
end

-- Best-effort: plays a named Animation instance on the model if its art has one, else
-- falls back to Config.Npc.Animations[name] (an asset id, empty by default). A missing
-- animation is silently skipped.
local function playAnimationIfPresent(bb: any, name: "Walk" | "Run" | "Flinch")
	local ok = pcall(function()
		local animator = bb.humanoid:FindFirstChildOfClass("Animator")
		if animator == nil then
			return
		end

		local animation = bb.character:FindFirstChild(name, true)
		if animation == nil or not animation:IsA("Animation") then
			local assetId = Config.Npc.Animations[name]
			if assetId == nil or assetId == "" then
				return
			end
			local fallback = Instance.new("Animation")
			fallback.AnimationId = assetId
			animator:LoadAnimation(fallback):Play()
			fallback:Destroy()
			return
		end

		animator:LoadAnimation(animation):Play()
	end)
	if not ok then
		log:Warn(string.format("%s: couldn't play %s animation", bb.character.Name, name))
	end
end

local flinch = BehaviorTree.Sequence({
	BehaviorTree.Condition(wasHit),
	BehaviorTree.Action(function(bb: any): BehaviorTree.Status
		playAnimationIfPresent(bb, "Flinch")
		return "Success"
	end),
})

local idle = BehaviorTree.Action(function(_bb: any): BehaviorTree.Status
	return "Success"
end)


-- Selector( Sequence(IsKnocked, Wait), Sequence(WasHit, Flinch), Idle ): no chasing or wandering.
function Trees.BuildDummy(): BehaviorTree.Node
	return BehaviorTree.Selector({
		BehaviorTree.Sequence({
			BehaviorTree.Condition(isKnocked),
			BehaviorTree.Wait(Config.Npc.TickSeconds),
		}),
		flinch,
		idle,
	})
end


local function distance(a: Vector3, b: Vector3): number
	return (a - b).Magnitude
end

local function targetRoot(bb: any): BasePart?
	local target = bb.target :: Model?
	if target == nil or target.Parent == nil then
		return nil
	end
	local root = target:FindFirstChild("HumanoidRootPart")
	local humanoid = target:FindFirstChildOfClass("Humanoid")
	if root == nil or not root:IsA("BasePart") or humanoid == nil or humanoid.Health <= 0 then
		return nil
	end
	return root :: BasePart
end

local function hasTarget(bb: any): boolean
	return targetRoot(bb) ~= nil
end

local function inReach(bb: any): boolean
	local root = targetRoot(bb)
	if root == nil then
		return false
	end
	return distance(bb.rootPart.Position, root.Position) <= Config.Npc.AttackRange
end

local function targetWithinGiveUpRadius(bb: any): boolean
	local root = targetRoot(bb)
	if root == nil then
		return false
	end
	return distance(bb.rootPart.Position, root.Position) <= Config.Npc.GiveUpRadius
end

local attack = BehaviorTree.Action(function(bb: any): BehaviorTree.Status
	-- Remembered so a later knockout can be told apart from one somebody else dealt.
	bb.attackedTarget = bb.target
	CombatService.Attack(bb.character)
	return "Success"
end)

-- Re-plans at most every 2s (AiController ticks every 0.2s; a full path that often
-- would be wasteful), and falls back to a direct MoveTo if pathing fails.
local PATH_REPLAN_SECONDS = 2
local WAYPOINT_REACHED_STUDS = 3

local function chaseStep(bb: any): BehaviorTree.Status
	local root = targetRoot(bb)
	if root == nil then
		return "Failure"
	end

	local now = os.clock()
	local waypoints = bb.waypoints :: { PathWaypoint }?
	local stale = bb.pathComputedAt == nil or (now - (bb.pathComputedAt :: number)) > PATH_REPLAN_SECONDS
	local exhausted = waypoints == nil or bb.waypointIndex > #waypoints

	if stale or exhausted then
		local path = PathfindingService:CreatePath({
			AgentRadius = 2,
			AgentHeight = 5,
			AgentCanJump = true,
			WaypointSpacing = 4,
		})
		local ok = pcall(function()
			path:ComputeAsync(bb.rootPart.Position, root.Position)
		end)
		bb.pathComputedAt = now
		if ok and path.Status == Enum.PathStatus.Success then
			bb.path = path
			bb.waypoints = path:GetWaypoints()
			bb.waypointIndex = 2 -- index 1 is the NPC's own current position
		else
			bb.path = nil
			bb.waypoints = nil
		end
	end

	waypoints = bb.waypoints :: { PathWaypoint }?
	if waypoints and bb.waypointIndex <= #waypoints then
		local waypoint = waypoints[bb.waypointIndex]
		bb.humanoid:MoveTo(waypoint.Position)
		if waypoint.Action == Enum.PathWaypointAction.Jump then
			bb.humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		end
		if distance(bb.rootPart.Position, waypoint.Position) <= WAYPOINT_REACHED_STUDS then
			bb.waypointIndex += 1
		end
	else
		bb.humanoid:MoveTo(root.Position)
	end

	playAnimationIfPresent(bb, "Run")
	return "Running"
end

local function giveUp(bb: any): BehaviorTree.Status
	bb.target = nil
	bb.path = nil
	bb.waypoints = nil
	bb.pathComputedAt = nil
	return "Success"
end

-- The nearest living player within ChaseRadius, or nil.
local function acquireTarget(bb: any): BehaviorTree.Status
	local nearest: Model? = nil
	local nearestDistance = Config.Npc.ChaseRadius
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if character and root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 and not StatusService.Has(character, "Knocked") then
			local d = distance(bb.rootPart.Position, (root :: BasePart).Position)
			if d <= nearestDistance then
				nearest = character
				nearestDistance = d
			end
		end
	end

	if nearest then
		bb.target = nearest
		return "Success"
	end
	return "Failure"
end

-- Roams a random point within WanderRadius of `home`; re-rolls once it
-- gets close, or if it's never actually picked a goal yet.
local function wander(bb: any): BehaviorTree.Status
	local goal = bb.wanderGoal :: Vector3?
	if goal == nil or distance(bb.rootPart.Position, goal) <= WAYPOINT_REACHED_STUDS then
		local angle = math.random() * math.pi * 2
		local radius = math.random() * Config.Npc.WanderRadius
		goal = (bb.home :: Vector3) + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		bb.wanderGoal = goal
	end
	bb.humanoid:MoveTo(goal :: Vector3)
	playAnimationIfPresent(bb, "Walk")
	return "Running"
end

-- Whether the target is a knocked-out player this NPC should now grip (Config.Npc.Target.gripsOnKnockout):
-- Knocked, and not already carried, jailed or gripped by someone else.
local function shouldGrip(bb: any): boolean
	if not Config.Npc.Target.gripsOnKnockout then
		return false
	end
	local target = bb.target :: Model?
	if target == nil or not StatusService.Has(target, "Knocked") then
		return false
	end
	-- Only a knockout this dummy dealt itself (the status names who did it), and not while it is
	-- waiting out the pause after a broken grip.
	local knocked = StatusService.Get(target, "Knocked")
	local by = if knocked and type(knocked.data) == "table" then (knocked.data :: any).by else nil
	if bb.attackedTarget ~= target or by ~= bb.character.Name then
		return false
	end
	if bb.regripAt ~= nil and os.clock() < bb.regripAt then
		return false
	end
	return not (StatusService.Has(target, "Carried") or StatusService.Has(target, "Jailed") or (StatusService.Has(target, "Gripped") and not GripService.IsGripping(bb.character)))
end

-- Walks up to a knocked-out target, then grips them. Running while the grip holds; Failure when it
-- cannot start (so the tree falls through to its other branches).
local function gripStep(bb: any): BehaviorTree.Status
	if GripService.IsGripping(bb.character) then
		bb.wasGripping = true
		return "Running"
	end
	if bb.wasGripping then
		-- The grip broke (a hit, a knockout): pause before trying again.
		bb.wasGripping = false
		bb.regripAt = os.clock() + Config.Npc.Target.regripCooldownSeconds
		return "Failure"
	end
	local target = bb.target :: Model?
	local victim = if target then Players:GetPlayerFromCharacter(target) else nil
	if victim == nil then
		return "Failure"
	end
	if not inReach(bb) then
		return chaseStep(bb)
	end
	local ok = GripService.Begin(bb.character, victim)
	return if ok then "Running" else "Failure"
end

-- Selector(
--   Sequence(IsKnocked, Wait),
--   Sequence(HasTarget, Selector(
--     Sequence(ShouldGrip, GripStep),
--     Sequence(InReach, Cooldown(AttackCooldown, Attack)),
--     Sequence(TargetWithin(GiveUpRadius), ChaseStep),
--     GiveUp
--   )),
--   Sequence(AcquireTarget within ChaseRadius, Success),
--   Wander(around home, WanderRadius)
-- )
function Trees.BuildTarget(): BehaviorTree.Node
	return BehaviorTree.Selector({
		BehaviorTree.Sequence({
			BehaviorTree.Condition(isKnocked),
			BehaviorTree.Wait(Config.Npc.TickSeconds),
		}),
		BehaviorTree.Sequence({
			BehaviorTree.Condition(hasTarget),
			BehaviorTree.Selector({
				BehaviorTree.Sequence({
					BehaviorTree.Condition(shouldGrip),
					BehaviorTree.Action(gripStep),
				}),
				BehaviorTree.Sequence({
					BehaviorTree.Condition(inReach),
					BehaviorTree.Cooldown(Config.Npc.AttackCooldown, attack),
				}),
				BehaviorTree.Sequence({
					BehaviorTree.Condition(targetWithinGiveUpRadius),
					BehaviorTree.Action(chaseStep),
				}),
				BehaviorTree.Action(giveUp),
			}),
		}),
		BehaviorTree.Action(acquireTarget),
		BehaviorTree.Action(wander),
	})
end

-- Training dummies: every trainer is Fist style, spawned by NpcService's `.dummy spawn`
-- (not auto-discovered like Dummy/Target). Each tree only acts through
-- CombatService.Attack/.AttackCancel/.SetBlocking and MovementService.Dash. A trainer
-- never chases or wanders; it stands still and reacts. Each decide function keeps its own
-- tiny state machine on the blackboard (`bb.phase`/`bb.phaseAt`, os.clock()-timed) rather
-- than nesting BehaviorTree.Wait/Cooldown nodes, whose fixed closure timer doesn't reset
-- when the guarding condition flips (fine for Sam/Sinbad's flat rhythm, wrong for reaction
-- windows that must restart).

-- The trainer's own target: prefers a valid bb.target (set directly by self-tests; a live
-- trainer keeps its last acquired target while alive) before acquiring a new one
-- (spawner in range, else nearest player in range).
local function findTrainerTarget(bb: any): Model?
	local engageRadius = (bb.engageRadius :: number?) or 12

	local spawner = bb.spawner :: Player?
	if spawner then
		local character = spawner.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if character and root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
			if distance(bb.rootPart.Position, (root :: BasePart).Position) <= engageRadius then
				return character
			end
		end
	end

	local nearest: Model? = nil
	local nearestDistance = engageRadius
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if character and root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
			local d = distance(bb.rootPart.Position, (root :: BasePart).Position)
			if d <= nearestDistance then
				nearest = character
				nearestDistance = d
			end
		end
	end
	return nearest
end

local function engageTrainerTarget(bb: any): boolean
	if targetRoot(bb) ~= nil then
		return true
	end
	local found = findTrainerTarget(bb)
	bb.target = found
	return found ~= nil
end

-- x/z away from the target in the trainer's own local space (MovementService.Dash's
-- contract), correct whichever way the trainer faces.
local function dashAway(bb: any): boolean
	local root = targetRoot(bb)
	if root == nil then
		return false
	end
	local away = bb.rootPart.Position - root.Position
	local flat = Vector3.new(away.X, 0, away.Z)
	if flat.Magnitude < 1e-3 then
		flat = bb.rootPart.CFrame.LookVector * -1
	end
	local localDir = bb.rootPart.CFrame:VectorToObjectSpace(flat.Unit)
	return MovementService.Dash(bb.character, localDir.X, localDir.Z)
end

-- Straight Sam: two-hit Fist chain on a fixed rhythm, never cancels or blocks
-- (CombatService.Attack throws the whole chain).
local function samDecide(bb: any, cfg: any): BehaviorTree.Status
	local now = os.clock()
	if bb.character:GetAttribute("Attacking") == true then
		return "Running"
	end
	if bb.phaseAt ~= nil and now - (bb.phaseAt :: number) < cfg.rhythmSeconds then
		return "Failure"
	end
	CombatService.Attack(bb.character)
	bb.phaseAt = now
	return "Success"
end

-- Turtle Tariq: holds block always, never attacks. Never parries: SetBlocking(true) on an
-- already-active block is a no-op, so the parry window opened on the first Apply expires
-- (Combat.Block.parryWindow) and is never refreshed.
local function tariqDecide(bb: any, _cfg: any): BehaviorTree.Status
	CombatService.SetBlocking(bb.character, true)
	return "Success"
end

-- Jabbing Jamal: idle (blocking) until the target STARTS any attack, then jabs after
-- reactionSeconds.
local function jamalDecide(bb: any, cfg: any): BehaviorTree.Status
	local target = bb.target :: Model
	local now = os.clock()
	local targetAttacking = target:GetAttribute("Attacking") == true

	if not targetAttacking then
		bb.phase = "idle"
		bb.phaseAt = nil
		CombatService.SetBlocking(bb.character, true)
		return "Success"
	end

	if bb.phase ~= "reacting" then
		bb.phase = "reacting"
		bb.phaseAt = now
	end
	if now - (bb.phaseAt :: number) >= (cfg.reactionSeconds or 0) then
		CombatService.Attack(bb.character)
		bb.phase = "idle"
		bb.phaseAt = nil
		return "Success"
	end
	return "Running"
end

-- Parry Pete: idle until the target's hit 1 of a swing, then reactionSeconds later times a
-- real parry (a fresh Block Apply; merely holding block opens no live parry window). The
-- read resets if the swing ends or moves past hit 1 first.
local function peteDecide(bb: any, cfg: any): BehaviorTree.Status
	local target = bb.target :: Model
	local now = os.clock()
	local attacking = target:GetAttribute("Attacking") == true
	local currentHit = target:GetAttribute("CurrentHitIndex")

	if bb.phase == "reacting" then
		if not (attacking and currentHit == 1) then
			bb.phase = "idle"
			bb.phaseAt = nil
			return "Failure"
		end
		if now - (bb.phaseAt :: number) >= (cfg.reactionSeconds or 0) then
			CombatService.SetBlocking(bb.character, true)
			bb.phase = "idle"
			bb.phaseAt = nil
			return "Success"
		end
		return "Running"
	end

	if attacking and currentHit == 1 then
		bb.phase = "reacting"
		bb.phaseAt = now
		return "Running"
	end

	return "Failure"
end

-- Feinting Mohammed: throws the Fist chain, cancels his OWN hit 2 on the first tick that
-- sees CurrentHitIndex == 2 (a scripted feint; no extra wait, since AI tick lag alone can
-- push a later cancel past cancelUntil + HitTolerance, which the server refuses), then
-- re-jabs immediately (Fist's cancelInto is "Any"). Repeats on rhythmSeconds; never blocks.
local function mohammedDecide(bb: any, cfg: any): BehaviorTree.Status
	local now = os.clock()
	local attacking = bb.character:GetAttribute("Attacking") == true
	local currentHit = bb.character:GetAttribute("CurrentHitIndex")

	if bb.phase == nil or bb.phase == "idle" then
		if bb.phaseAt ~= nil and now - (bb.phaseAt :: number) < cfg.rhythmSeconds then
			return "Failure"
		end
		CombatService.Attack(bb.character)
		bb.phase = "thrown"
		bb.phaseAt = now
		return "Running"
	end

	if bb.phase == "thrown" then
		if not attacking then
			-- Landed clean some other way (e.g. a target it interrupted): the rhythm timer restarts.
			bb.phase = "idle"
			bb.phaseAt = now
			return "Failure"
		end
		if currentHit == 2 then
			CombatService.AttackCancel(bb.character)
			bb.phase = "cancelled"
			bb.phaseAt = now
			return "Running"
		end
		return "Running"
	end

	CombatService.Attack(bb.character)
	bb.phase = "idle"
	bb.phaseAt = now
	return "Success"
end

-- Dashing Dalila: dashes away when the target starts any attack (reactionSeconds later,
-- like Jamal); otherwise jabs on rhythmSeconds.
local function dalilaDecide(bb: any, cfg: any): BehaviorTree.Status
	local target = bb.target :: Model
	local now = os.clock()
	local targetAttacking = target:GetAttribute("Attacking") == true

	if targetAttacking then
		if bb.phase ~= "reacting" then
			bb.phase = "reacting"
			bb.phaseAt = now
		end
		if now - (bb.phaseAt :: number) >= (cfg.reactionSeconds or 0) then
			dashAway(bb)
			bb.phase = "idle"
			bb.phaseAt = now
			return "Success"
		end
		return "Running"
	end

	-- A lone jab, not the full chain: the same self-cancel Mohammed uses
	-- (CombatService.AttackCancel once CurrentHitIndex becomes 2) without his re-jab; she
	-- never commits to the second hit.
	if bb.phase == "jabbing" then
		if bb.character:GetAttribute("Attacking") ~= true then
			-- Ended some other way (e.g. interrupted) before reaching hit 2: the rhythm timer restarts.
			bb.phase = "idle"
			bb.phaseAt = now
			return "Failure"
		end
		if bb.character:GetAttribute("CurrentHitIndex") == 2 then
			CombatService.AttackCancel(bb.character)
			bb.phase = "idle"
			bb.phaseAt = now
			return "Success"
		end
		return "Running"
	end

	bb.phase = "idle"
	if bb.phaseAt ~= nil and now - (bb.phaseAt :: number) < cfg.rhythmSeconds then
		return "Failure"
	end
	CombatService.Attack(bb.character)
	bb.phase = "jabbing"
	bb.phaseAt = now
	return "Running"
end

-- Sparring Sinbad: picks throw/cancel/parry/dash by Config.Npc.Trainers.SparringSinbad.weights
-- every rhythmSeconds. A cancel with nothing in progress, or a dash with no target in range,
-- are safe no-ops in the services underneath.
local SINBAD_ACTIONS = { "throw", "cancel", "parry", "dash" }

-- Exposed so self-tests can prove the weighting math with a fixed roll.
function Trees.WeightedPick(weights: { [string]: number }, roll: number): string
	local total = 0
	for _, key in SINBAD_ACTIONS do
		total += math.max(weights[key] or 0, 0)
	end
	if total <= 0 then
		return SINBAD_ACTIONS[1]
	end
	local target = math.clamp(roll, 0, 1) * total
	local sum = 0
	for _, key in SINBAD_ACTIONS do
		sum += math.max(weights[key] or 0, 0)
		if target < sum then
			return key
		end
	end
	return SINBAD_ACTIONS[#SINBAD_ACTIONS]
end

local function sinbadDecide(bb: any, cfg: any): BehaviorTree.Status
	local now = os.clock()
	if bb.phaseAt ~= nil and now - (bb.phaseAt :: number) < cfg.rhythmSeconds then
		return "Failure"
	end
	bb.phaseAt = now

	local choice = Trees.WeightedPick(cfg.weights or {}, math.random())
	if choice == "throw" then
		CombatService.Attack(bb.character)
	elseif choice == "cancel" then
		CombatService.AttackCancel(bb.character)
	elseif choice == "parry" then
		CombatService.SetBlocking(bb.character, true)
	elseif choice == "dash" then
		dashAway(bb)
	end
	return "Success"
end

local TRAINER_DECIDERS: { [string]: (bb: any, cfg: any) -> BehaviorTree.Status } = {
	StraightSam = samDecide,
	TurtleTariq = tariqDecide,
	JabbingJamal = jamalDecide,
	ParryPete = peteDecide,
	FeintingMohammed = mohammedDecide,
	DashingDalila = dalilaDecide,
	SparringSinbad = sinbadDecide,
}

-- `cfgOverride` lets a self-test swap in tiny reaction/rhythm numbers (and, for Sinbad, a
-- skewed weight table). A live trainer always calls this with no override.
function Trees.BuildTrainer(key: string, cfgOverride: { [string]: any }?): BehaviorTree.Node
	local decide = TRAINER_DECIDERS[key]
	if decide == nil then
		error(string.format("Trees.BuildTrainer: unknown trainer %q", key))
	end
	local cfg = cfgOverride or Config.Npc.Trainers[key]

	return BehaviorTree.Selector({
		BehaviorTree.Sequence({
			BehaviorTree.Condition(isKnocked),
			BehaviorTree.Wait(Config.Npc.TickSeconds),
		}),
		BehaviorTree.Sequence({
			BehaviorTree.Condition(engageTrainerTarget),
			BehaviorTree.Action(function(bb: any): BehaviorTree.Status
				return decide(bb, cfg)
			end),
		}),
		idle,
	})
end

return Trees
