--!strict
-- Client bootstrap. Contract for every module in Controllers:
--   Init()  sets up state and must not yield.
--   Start() may yield and may call into other controllers (every Init has already run).

local Controllers = script.Parent.Controllers

-- Returns are typed as variadic (not `()`) so pcall(controller.Init, controller)
-- below type-checks as (boolean, ...any) instead of just (boolean); a real
-- Init/Start still isn't expected to return anything meaningful.
type ControllerModule = {
	Init: ((self: any) -> ...any)?,
	Start: ((self: any) -> ...any)?,
}

local moduleScripts: { ModuleScript } = {}
for _, child in Controllers:GetChildren() do
	if child:IsA("ModuleScript") then
		table.insert(moduleScripts, child)
	end
end

table.sort(moduleScripts, function(a, b)
	return a.Name < b.Name
end)

local controllers: { ControllerModule } = {}
local names: { string } = {}

for _, moduleScript in moduleScripts do
	local ok, result = pcall(require, moduleScript)
	if ok then
		table.insert(controllers, result :: ControllerModule)
		table.insert(names, moduleScript.Name)
	else
		warn(string.format("[Client.Main] require(%s) failed: %s", moduleScript.Name, tostring(result)))
	end
end

for i, controller in controllers do
	if type(controller) == "table" and type(controller.Init) == "function" then
		local ok, err = pcall(controller.Init, controller)
		if not ok then
			warn(string.format("[Client.Main] %s.Init() failed: %s", names[i], tostring(err)))
		end
	end
end

for i, controller in controllers do
	if type(controller) == "table" and type(controller.Start) == "function" then
		local name = names[i]
		task.spawn(function()
			local ok, err = pcall(controller.Start, controller)
			if not ok then
				warn(string.format("[Client.Main] %s.Start() failed: %s", name, tostring(err)))
			end
		end)
	end
end
