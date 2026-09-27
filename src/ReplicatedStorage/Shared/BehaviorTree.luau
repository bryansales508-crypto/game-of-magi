--!strict
-- A small, readable behavior tree (M3-04, TRIAGE #20). Trees are built as
-- plain data (each factory below returns a Node - just a table holding a
-- `Tick` function) and driven by whoever owns the blackboard on their own
-- schedule; this module has no timers, threads or Roblox services of its
-- own, only node semantics, so it's trivially self-tested with a fake
-- blackboard table.
--
-- Standard three-state BT semantics:
--   Success - the node finished, and finished well.
--   Failure - the node finished, and didn't.
--   Running - the node isn't done yet; tick it again next time.
-- A blackboard is just a table the tree's Condition/Action functions read
-- and write; this module never looks inside it.

export type Status = "Success" | "Failure" | "Running"

export type Node = {
	Tick: (blackboard: any) -> Status,
}

local BehaviorTree = {}

-- Ticks children in order; the first child that isn't Failure decides the
-- result (Success or Running short-circuits immediately). Failure only if
-- every child fails - "try each option until one works."
function BehaviorTree.Selector(children: { Node }): Node
	return {
		Tick = function(blackboard: any): Status
			for _, child in children do
				local status: Status = child.Tick(blackboard)
				if status ~= "Failure" then
					return status
				end
			end
			return "Failure"
		end,
	}
end

-- Ticks children in order; the first child that isn't Success decides the
-- result (Failure or Running short-circuits immediately). Success only if
-- every child succeeds - "do each step in order."
function BehaviorTree.Sequence(children: { Node }): Node
	return {
		Tick = function(blackboard: any): Status
			for _, child in children do
				local status: Status = child.Tick(blackboard)
				if status ~= "Success" then
					return status
				end
			end
			return "Success"
		end,
	}
end

-- A boolean check: Success if true, Failure if false. Never Running.
function BehaviorTree.Condition(fn: (blackboard: any) -> boolean): Node
	return {
		Tick = function(blackboard: any): Status
			if fn(blackboard) then
				return "Success"
			end
			return "Failure"
		end,
	}
end

-- A leaf that does something and reports how it went - the only node that
-- can return "Running" on its own (a multi-tick action, e.g. still
-- walking to a waypoint).
function BehaviorTree.Action(fn: (blackboard: any) -> Status): Node
	return {
		Tick = fn,
	}
end

-- Flips Success <-> Failure; Running passes through unchanged.
function BehaviorTree.Inverter(child: Node): Node
	return {
		Tick = function(blackboard: any): Status
			local status: Status = child.Tick(blackboard)
			if status == "Success" then
				return "Failure"
			elseif status == "Failure" then
				return "Success"
			end
			return status
		end,
	}
end

-- Running for `seconds` (real time, os.clock()), then Success once, then
-- resets so the same node can be waited on again the next time it's
-- entered fresh. Each Cooldown/Wait node keeps its own timer in a closure,
-- so a tree built fresh per NPC (Trees.luau's job) never shares timer
-- state between NPCs.
function BehaviorTree.Wait(seconds: number): Node
	local startedAt: number? = nil
	return {
		Tick = function(_blackboard: any): Status
			local now = os.clock()
			if startedAt == nil then
				startedAt = now
			end
			if now - (startedAt :: number) >= seconds then
				startedAt = nil
				return "Success"
			end
			return "Running"
		end,
	}
end

-- Gates `child` behind a cooldown: once `child` returns Success, further
-- ticks return Failure (not Running - a node on cooldown isn't "doing"
-- anything) until `seconds` have passed, then `child` can run again.
function BehaviorTree.Cooldown(seconds: number, child: Node): Node
	local readyAt: number = 0
	return {
		Tick = function(blackboard: any): Status
			if os.clock() < readyAt then
				return "Failure"
			end
			local status: Status = child.Tick(blackboard)
			if status == "Success" then
				readyAt = os.clock() + seconds
			end
			return status
		end,
	}
end

return BehaviorTree
