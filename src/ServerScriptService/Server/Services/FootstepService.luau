--!strict
-- Footstep sounds and sand/mud footprints (M3-03: moved verbatim out of
-- the deleted Interactions/InteractionsHandler.server.luau, which also
-- handled combat - the rest of that file goes with the deletion, TRIAGE
-- #10; this one small piece still works today and keeps working exactly
-- as before. TRIAGE #16 rebuilds it properly in M6 (real footstep
-- detection instead of the client firing a remote per animation step).
--
-- Still uses the OLD MiscRemotes.Footstep remote directly (unvalidated),
-- same as before - it isn't part of the new Shared/Remotes.luau registry
-- yet, on purpose (M6's job).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local ColorMath = require(ReplicatedStorage.Modules.ColorMath)

local log = Log.new("FootstepService")

type Step = "Right" | "Left" | "Jump"

local HARD_SURFACES: { [string]: boolean } =
	{ Rock = true, Sandstone = true, RoofShingles = true, Pavement = true, Slate = true }
local DIRT_SURFACES: { [string]: boolean } = { Sand = true, Dirt = true, Mud = true }
local THUD_SURFACES: { [string]: boolean } = { Wood = true, Carpet = true }

local function materialName(material: Enum.Material): string
	return material.Name
end

local function isRunning(character: Model): boolean
	local intFold = character:FindFirstChild("IntFold")
	local runningValue = intFold and intFold:FindFirstChild("Running?")
	return runningValue ~= nil and runningValue:IsA("BoolValue") and runningValue.Value
end

local function playFirstStopped(torso: Instance, namePart: string, volume: number)
	local sound = torso:FindFirstChild(namePart)
	if sound == nil or not sound:IsA("Sound") then
		return
	end
	if sound.IsPlaying then
		return
	end
	sound.Volume = volume
	sound:Play()
	local restoreConn: RBXScriptConnection
	restoreConn = sound.Ended:Connect(function()
		sound.Volume = 0.1
		restoreConn:Disconnect()
	end)
end

local function playSurfaceSound(torso: Instance, character: Model, step: Step, suffix: string)
	local volume = if isRunning(character) then 0.25 else 0.1
	if step == "Right" then
		playFirstStopped(torso, "Right" .. suffix, volume)
	else
		-- "Left" and "Jump" both land on the left-foot sound, same as the
		-- old code.
		playFirstStopped(torso, "Left" .. suffix, volume)
	end
end

-- Drops a fading footprint block under the character on sand/mud, same
-- shape and fade the old code used.
local function placeFootprint(character: Model, step: Step, floorResult: RaycastResult)
	local projectiles = Workspace:FindFirstChild("Projectiles")
	if projectiles == nil then
		return
	end

	local running = isRunning(character)
	local predict = if running then 8 else 2

	local function makeBlock(legName: string): Part?
		local leg = character:FindFirstChild(legName)
		if leg == nil or not leg:IsA("BasePart") then
			return nil
		end
		local block = Instance.new("Part")
		block.CanCollide = false
		block.Anchored = true
		block.Size = Vector3.new(1.5, 0.25, 1.5)
		block.Material = floorResult.Material
		block.Color = ColorMath.mul(floorResult.Instance.Color, Color3.new(0.8, 0.8, 0.8))

		local lookVector = leg.CFrame.LookVector
		block.CFrame = leg.CFrame + (lookVector * predict)
		block.Orientation = Vector3.new(0, block.Orientation.Y, block.Orientation.Z)
		block.Position = Vector3.new(block.Position.X, floorResult.Position.Y, block.Position.Z)
		block.Parent = projectiles

		local tween = TweenService:Create(block, TweenInfo.new(0.75, Enum.EasingStyle.Linear), { Transparency = 1 })
		tween:Play()
		tween.Completed:Connect(function()
			block:Destroy()
		end)
		return block
	end

	if step ~= "Jump" then
		makeBlock(step .. " Leg")
	else
		makeBlock("Right Leg")
		makeBlock("Left Leg")
	end
end

-- Typed as variadic (not `()`) so pcall(onFootstep, ...) below type-checks
-- as (boolean, ...any) instead of just (boolean) - same trick Remotes.luau
-- uses for its own handlers.
local function onFootstep(player: Player, step: Step, _idle: boolean?): ...any
	local character = player.Character
	if character == nil then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local torso = character:FindFirstChild("Torso")
	local effects = character:FindFirstChild("Effects")
	if humanoid == nil or torso == nil or effects == nil then
		return
	end

	if effects:FindFirstChild("MutedStep") then
		return
	end

	local floorMaterial = humanoid.FloorMaterial
	local floorResult: RaycastResult? = nil

	if floorMaterial == Enum.Material.Air and step ~= "Jump" then
		-- Only a Jump step bothers raycasting while airborne (matches the
		-- old code: a regular walk step in the air is just skipped).
		return
	end

	if step == "Jump" or floorMaterial == Enum.Material.Air then
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if hrp == nil or not hrp:IsA("BasePart") then
			return
		end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local characters = Workspace:FindFirstChild("Characters")
		params.FilterDescendantsInstances = if characters then { characters } else {}
		floorResult = Workspace:Raycast((hrp :: BasePart).Position, Vector3.new(0, -1000, 0), params)
		if floorResult == nil then
			return
		end
		floorMaterial = floorResult.Material
	end

	local name = materialName(floorMaterial)
	if HARD_SURFACES[name] then
		playSurfaceSound(torso, character, step, "Block")
	elseif DIRT_SURFACES[name] then
		playSurfaceSound(torso, character, step, "Dirt")
	elseif THUD_SURFACES[name] then
		playSurfaceSound(torso, character, step, "Carpet")
	end

	if (name == "Sand" or name == "Mud") and floorResult then
		placeFootprint(character, step, floorResult)
	end
end

local FootstepService = {}

function FootstepService:Init()
	local footEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("MiscRemotes"):WaitForChild("Footstep")
	if not footEvent:IsA("RemoteEvent") then
		log:Error("MiscRemotes.Footstep is not a RemoteEvent; footsteps won't work")
		return
	end

	(footEvent :: RemoteEvent).OnServerEvent:Connect(function(player: Player, step: any, idle: any)
		if step ~= "Right" and step ~= "Left" and step ~= "Jump" then
			return
		end
		local ok, err = pcall(onFootstep, player, step :: Step, if type(idle) == "boolean" then idle else nil)
		if not ok then
			log:Error(string.format("footstep handling for %s errored: %s", player.Name, tostring(err)))
		end
	end)
end

function FootstepService:Start() end

return FootstepService
