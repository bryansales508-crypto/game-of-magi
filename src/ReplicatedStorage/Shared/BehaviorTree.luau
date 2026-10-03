--!strict
-- A small behavior tree. Trees are plain data (each factory returns a Node, a table holding a `Tick` function) driven by whoever owns the blackboard on their own schedule; no timers, threads or Roblox services here, only node semantics. Statuses: Success (finished well), Failure (finished badly), Running (tick again next time). The blackboard is a table the Condition/Action functions read and write; this module never looks inside it.

export type Status = "Success" | "Failure" | "Running"

export type Node = {
	Tick: (blackboard: any) -> Status,
}

local BehaviorTree = {}

-- Ticks children in order; the first child that isn't Failure decides the result. Failure only if every child fails.
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

-- Ticks children in order; the first child that isn't Success decides the result. Success only if every child succeeds.
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

-- Success if true, Failure if false. Never Running.
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

-- A leaf that does something and reports how it went; the only node that can return Running on its own.
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

-- Running for `seconds` (os.clock()), then Success once, then resets. Each Wait/Cooldown keeps its own timer in a closure, so a tree built fresh per NPC never shares timer state.
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

-- Gates `child` behind a cooldown: after `child` returns Success, ticks return Failure (not Running) until `seconds` have passed.
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
