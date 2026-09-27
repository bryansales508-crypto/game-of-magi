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
local StatusService = require(script.Parent.Parent.StatusService)
local CombatService = require(script.Parent.Parent.CombatService)

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

return Trees
