--!strict
-- Per-NPC state and the tick loop's entry point. Holds the blackboard a tree's
-- Condition/Action nodes read and write, and the tree itself (built by Trees.luau and
-- passed in; AiController never requires Trees, avoiding a cyclic require).

local BehaviorTree = require(game:GetService("ReplicatedStorage").Shared.BehaviorTree)

export type Blackboard = {
	character: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	npcType: string,
	-- The point Wander roams around: where this NPC started.
	home: Vector3,
	target: Model?,
	wanderGoal: Vector3?,
	path: Path?,
	waypoints: { PathWaypoint }?,
	waypointIndex: number,
	pathComputedAt: number?,
	-- Training-dummy-only fields (nil for Dummy/Target), set by NpcService right after
	-- AiController.new; Trees.luau's trainer decide functions read/write trainerKey/spawner/
	-- engageRadius and the small phase/phaseAt state machine.
	trainerKey: string?,
	spawner: Player?,
	engageRadius: number?,
	phase: string?,
	phaseAt: number?,
}

export type AiController = {
	character: Model,
	npcType: string,
	blackboard: Blackboard,
	tree: BehaviorTree.Node,
	Tick: (self: AiController) -> (),
}

local AiController = {}
AiController.__index = AiController

-- nil if `character` isn't a usable rig (no Humanoid/HumanoidRootPart) -
-- the caller (NpcService) just skips registering it and logs why.
function AiController.new(character: Model, npcType: string, tree: BehaviorTree.Node): AiController?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or rootPart == nil or not rootPart:IsA("BasePart") then
		return nil
	end

	local blackboard: Blackboard = {
		character = character,
		humanoid = humanoid,
		rootPart = rootPart :: BasePart,
		npcType = npcType,
		home = (rootPart :: BasePart).Position,
		target = nil,
		wanderGoal = nil,
		path = nil,
		waypoints = nil,
		waypointIndex = 1,
		pathComputedAt = nil,
	}

	local self = setmetatable({
		character = character,
		npcType = npcType,
		blackboard = blackboard,
		tree = tree,
	}, AiController)

	return (self :: any) :: AiController
end

function AiController:Tick()
	if self.character.Parent == nil or self.blackboard.humanoid.Parent == nil then
		return
	end
	self.tree.Tick(self.blackboard)
end

return AiController
