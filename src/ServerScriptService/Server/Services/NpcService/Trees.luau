--!strict
-- The Dummy and Target behavior trees (M3-04, TRIAGE #20, fixes AUDIT
-- M19). Built fresh per NPC (BuildDummy()/BuildTarget() are factories, not
-- singletons), so Cooldown/Wait's own per-node timers never leak between
-- NPCs. Every Condition/Action here reads/writes an AiController.Blackboard
-- passed in as `blackboard: any` (matching BehaviorTree.luau's own generic
-- typing) - AiController.luau's actual Blackboard type is what the real
-- callers use; this module doesn't require AiController back (that would
-- be a cyclic ModuleScript require).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")

local Log = require(ReplicatedStorage.Shared.Log)
local Config = require(ReplicatedStorage.Shared.Config)
local BehaviorTree = require(ReplicatedStorage.Shared.BehaviorTree)
local Combat = require(ReplicatedStorage.Shared.Data.Combat)
local StatusService = require(script.Parent.Parent.StatusService)
local CombatService = require(script.Parent.Parent.CombatService)
local MovementService = require(script.Parent.Parent.MovementService)

local log = Log.new("NpcService")

local Trees = {}

-- ==================== shared conditions/actions ====================

local function isKnocked(bb: any): boolean
	return StatusService.Has(bb.character, "Knocked")
end

local function wasHit(bb: any): boolean
	return StatusService.Has(bb.character, "Hit")
end

-- Best-effort: plays an existing Animation by name if the NPC's art
-- happens to have one (Bryan's rig, untouched by this task - there's no
-- Studio access here to know what's actually there, so this only ever
-- reacts to what it finds; a missing animation is silently skipped, never
-- an error).
-- REVIEW-M3-04 L2: tries an existing named Animation instance on the
-- model first (Bryan's own art, if it's there); falls back to
-- Config.Npc.Animations[name] (an asset id, empty by default) so Bryan can
-- fill in either one without a code change.
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

-- ==================== Dummy ====================

-- Selector( Sequence(IsKnocked, Wait), Sequence(WasHit, Flinch), Idle ).
-- Old SYSTEMS 15: "only plays walk and run animations and flinches when
-- hit" - no chasing, no wandering.
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

-- ==================== Target ====================

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
	CombatService.Attack(bb.character)
	return "Success"
end)

-- Re-plans at most every 2s (a "small path cache" - AiController ticks
-- every 0.2s, recomputing a full path that often would be wasteful), and
-- falls back to a direct MoveTo if pathing fails.
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

-- Selector(
--   Sequence(IsKnocked, Wait),
--   Sequence(HasTarget, Selector(
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

-- ==================== Training dummies (M3B-02) ====================
-- docs/M3B-PLAN.md section 3, Bryan's roster, approved 2026-09-28. Every
-- trainer is Fist style, spawned by NpcService's `.dummy spawn` (not
-- auto-discovered like Dummy/Target above) - see NpcService for the
-- spawn/reset/name-tag side of this. Each tree only acts through
-- CombatService.Attack/.AttackCancel/.SetBlocking and MovementService.Dash -
-- AttackCancel joins the two Bryan named explicitly (Attack/SetBlocking/
-- Dash) because Feinting Mohammed's whole habit (throw the light, cancel
-- the telegraphed heavy, re-jab) has no other way to exist: it's an
-- existing public CombatService entry point, not a new one.
--
-- A trainer never chases or wanders - it stands still and reacts, so
-- there's no path-finding half here the way Target has. Each decide
-- function below keeps its own tiny state machine on the blackboard itself
-- (`bb.phase`/`bb.phaseAt`, os.clock()-timed) rather than nesting more
-- BehaviorTree.Wait/Cooldown nodes: those keep one fixed timer in their own
-- closure that doesn't reset when the condition guarding them goes false
-- and true again (fine for Sam/Sinbad's flat rhythin below, wrong for
-- Jamal/Pete/Dalila's "the read has to restart if what they're reading
-- stops" reaction windows).

-- The trainer's own target: prefers whatever bb.target already validly is
-- (a self-test sets this directly; a live trainer just keeps its last
-- acquired target as long as it's still alive) before trying to acquire a
-- new one (spawner in range, else the nearest player in range).
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

-- x/z away from the target, in the trainer's own local space
-- (MovementService.Dash's own contract) - correct regardless of which way
-- the trainer happens to be facing.
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

-- Straight Sam: light-heavy straight on a fixed rhythm, never cancels
-- (CombatService.Attack throws the WHOLE chain itself - there's nothing
-- here that could cancel it even if it wanted to), never blocks.
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

-- Turtle Tariq: holds block always, never attacks. "Never parries": once
-- already blocking, SetBlocking(true) is a no-op (CombatService.SetBlocking
-- returns early on an already-active block), so the one parry window
-- StatusService opened on the FIRST Apply expires on its own
-- (Combat.Block.parryWindow) and is never refreshed.
local function tariqDecide(bb: any, _cfg: any): BehaviorTree.Status
	CombatService.SetBlocking(bb.character, true)
	return "Success"
end

-- Jabbing Jamal: idle (blocking) until the target's Heavy wind-up starts
-- (CurrentHit == "Heavy" while they're mid-swing), then jabs after
-- reactionSeconds - the bait-and-punish Bryan's teaching order wants here.
local function jamalDecide(bb: any, cfg: any): BehaviorTree.Status
	local target = bb.target :: Model
	local now = os.clock()
	local heavyWindup = target:GetAttribute("Attacking") == true and target:GetAttribute("CurrentHit") == "Heavy"

	if not heavyWindup then
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

-- Parry Pete: idle until the target's first Light of a swing, then times a
-- real parry (a fresh Block Apply - not just holding it, which is what
-- actually opens a live parry window) reactionSeconds later. The read
-- resets if the swing ends (or moves past Light) before the timer fires.
local function peteDecide(bb: any, cfg: any): BehaviorTree.Status
	local target = bb.target :: Model
	local now = os.clock()
	local attacking = target:GetAttribute("Attacking") == true
	local currentHit = target:GetAttribute("CurrentHit")

	if bb.phase == "reacting" then
		if not (attacking and currentHit == "Light") then
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

	if attacking and currentHit == "Light" then
		bb.phase = "reacting"
		bb.phaseAt = now
		return "Running"
	end

	return "Failure"
end

-- Feinting Mohammed: throws the light-heavy Fist chain, but cancels his OWN
-- heavy the instant its cancelUntil passes (a scripted, telegraphed feint,
-- not a reaction to the target), then re-jabs immediately (Fist's
-- cancelInto is "Any" - nothing auto-fires the way Dagger's "Jab" would).
-- Repeats on rhythmSeconds; never blocks.
local FIST_HEAVY_CANCEL_UNTIL = (Combat.styleFor("Fist") :: Combat.Style).chain[2].cancelUntil

local function mohammedDecide(bb: any, cfg: any): BehaviorTree.Status
	local now = os.clock()
	local attacking = bb.character:GetAttribute("Attacking") == true
	local currentHit = bb.character:GetAttribute("CurrentHit")

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
			-- Landed clean some other way (a target it interrupted, e.g.) -
			-- the rhythm timer restarts from here either way.
			bb.phase = "idle"
			bb.phaseAt = now
			return "Failure"
		end
		if currentHit == "Heavy" and now - (bb.phaseAt :: number) >= FIST_HEAVY_CANCEL_UNTIL then
			CombatService.AttackCancel(bb.character)
			bb.phase = "cancelled"
			bb.phaseAt = now
			return "Running"
		end
		return "Running"
	end

	-- bb.phase == "cancelled"
	CombatService.Attack(bb.character)
	bb.phase = "idle"
	bb.phaseAt = now
	return "Success"
end

-- Dashing Dalila: dashes away the moment the target's Heavy wind-up starts
-- (reactionSeconds later, the same read as Jamal); otherwise jabs on
-- rhythmSeconds like Sam's first hit alone.
local function dalilaDecide(bb: any, cfg: any): BehaviorTree.Status
	local target = bb.target :: Model
	local now = os.clock()
	local heavyWindup = target:GetAttribute("Attacking") == true and target:GetAttribute("CurrentHit") == "Heavy"

	if heavyWindup then
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

	-- REVIEW-M3B-02: a lone jab, not the full chain - the exact same
	-- self-cancel Feinting Mohammed uses (CombatService.AttackCancel once
	-- her own CurrentHit becomes "Heavy"), just without his re-jab: she
	-- just pokes once per rhythmSeconds and waits for the next cycle,
	-- never committing to a heavy on her own initiative.
	if bb.phase == "jabbing" then
		if bb.character:GetAttribute("Attacking") ~= true then
			-- Ended some other way (interrupted, say) before ever reaching
			-- the heavy - the rhythm timer restarts from here either way.
			bb.phase = "idle"
			bb.phaseAt = now
			return "Failure"
		end
		if bb.character:GetAttribute("CurrentHit") == "Heavy" then
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

-- Sparring Sinbad: picks throw/cancel/parry/dash by Config.Npc.Trainers.
-- SparringSinbad.weights every rhythmSeconds. "Reacts to the target's own
-- state" shows up in what each pick actually DOES rather than in the pick
-- itself: a cancel with nothing in progress, or a dash with no target in
-- range, are already safe no-ops in the services underneath (nothing extra
-- to gate here).
local SINBAD_ACTIONS = { "throw", "cancel", "parry", "dash" }

-- Exposed (not local) so self-tests can prove the weighting math directly,
-- with a fixed roll, independent of math.random() and of Config's own
-- frozen tables.
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

-- `cfgOverride` lets a self-test swap in tiny reaction/rhythm numbers (and,
-- for Sinbad, a skewed weight table) instead of waiting out Config.Npc.
-- Trainers' own real-feel placeholders, and instead of touching Config's
-- own frozen tables to do it. A live trainer (NpcService's `.dummy spawn`)
-- always calls this with no override.
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
