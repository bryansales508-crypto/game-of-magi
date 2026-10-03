--!strict
-- Server bootstrap. Contract for every module in Services:
--   Init()  sets up state and must not yield.
--   Start() may yield and may call into other services (every Init has already run).

local Services = script.Parent.Services

-- Returns are typed as variadic so pcall(service.Init, service) type-checks.
type ServiceModule = {
	Init: ((self: any) -> ...any)?,
	Start: ((self: any) -> ...any)?,
}

local moduleScripts: { ModuleScript } = {}
for _, child in Services:GetChildren() do
	if child:IsA("ModuleScript") then
		table.insert(moduleScripts, child)
	end
end

table.sort(moduleScripts, function(a, b)
	return a.Name < b.Name
end)

local services: { ServiceModule } = {}
local names: { string } = {}

for _, moduleScript in moduleScripts do
	local ok, result = pcall(require, moduleScript)
	if ok then
		table.insert(services, result :: ServiceModule)
		table.insert(names, moduleScript.Name)
	else
		warn(string.format("[Server.Main] require(%s) failed: %s", moduleScript.Name, tostring(result)))
	end
end

for i, service in services do
	if type(service) == "table" and type(service.Init) == "function" then
		local ok, err = pcall(service.Init, service)
		if not ok then
			warn(string.format("[Server.Main] %s.Init() failed: %s", names[i], tostring(err)))
		end
	end
end

for i, service in services do
	if type(service) == "table" and type(service.Start) == "function" then
		local name = names[i]
		task.spawn(function()
			local ok, err = pcall(service.Start, service)
			if not ok then
				warn(string.format("[Server.Main] %s.Start() failed: %s", name, tostring(err)))
			end
		end)
	end
end
