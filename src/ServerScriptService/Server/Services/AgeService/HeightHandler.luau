--!strict
-- Resizes a character's body parts, joints, attachments and accessories to a
-- height/build ratio.

local ReplicatedFirst = game:GetService("ReplicatedFirst")
local Lighting = game:GetService("Lighting")

export type CloakOffset = {
	pos: Vector3,
	rot: Vector3,
	drift: Vector3,
}

local HeightHandler = {}

-- Per-cloak fit offsets (position/rotation correction + how much the cloak
-- drifts with height). Anything else found under ReplicatedFirst.Assets at
-- module load gets an empty entry below, so isGameHat still recognizes it
-- (as a body-attached accessory with no correction) even without a curated
-- offset.
local gameHats: { [string]: CloakOffset | {} } = {
	["Torn Cloak"] = { pos = Vector3.new(0, 0.3, -0.05), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 2, 0.25) },
	["Super Torn Cloak"] = { pos = Vector3.new(0, -0.15, -0.275), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 1.75, 0.25) },
	["Shoulder Cloth"] = { pos = Vector3.new(-1.375, 0.4, 0.05), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 0.25, 0) },
	["Shoulder Cloak"] = { pos = Vector3.new(0.38, -0.1, 0), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 1.75, 0) },
	["Short Wrap"] = { pos = Vector3.new(-0.175, 0, 0), rot = Vector3.new(0, 180, 5), drift = Vector3.new(0, 0.5, 0.1) },
	["Short Shoulder Cloak"] = { pos = Vector3.new(1.45, 0.4, 0.03), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 0.5, 0) },
	["Ripped Bandana"] = { pos = Vector3.new(0, -0.3, -0.15), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 1.25, 0.25) },
	["Proper Cloak"] = { pos = Vector3.new(-0.05, -0.009, 0), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 0.4, 0) },
	["Low Bandana"] = { pos = Vector3.new(0, -0.5, 0.1), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 0.4, 0) },
	["Long Wrap"] = { pos = Vector3.new(0, 0.25, -0.25), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 1.2, 0) },
	["Long Scarf"] = { pos = Vector3.new(0, -0.1, 0.05), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 1.125, 0) },
	["Full Shoulder Cloak"] = { pos = Vector3.new(0, -0.18, -0.475), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 1.5, 0) },
	["Flamboyant Scarf"] = { pos = Vector3.new(0, -0.3, 0), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 2, 0.25) },
	["Fancy Shawl"] = { pos = Vector3.new(0, 0, 0.025), rot = Vector3.new(0, 180, 0), drift = Vector3.new(0, 1, 0.25) },
}

local assetsFolder = ReplicatedFirst:FindFirstChild("Assets")
if assetsFolder then
	for _, child in assetsFolder:GetChildren() do
		if gameHats[child.Name] == nil then
			gameHats[child.Name] = {}
		end
	end
end

-- height: 1 = normal, >1 = taller, <1 = shorter
-- skinniness: 0 = no width change (pure stretch), 0.5 = volume-preserving (natural), 1 = aggressive
function HeightHandler.heightToRatio(height: number, skinniness: number?): Vector3
	local skin = skinniness or 0.5
	local width = height ^ (-skin)
	return Vector3.new(width, height, width)
end

function HeightHandler.isGameHat(name: string): boolean
	return gameHats[name] ~= nil
end

-- How much the head (and hats) respond to overall body size. 1 = full, 0 = never.
local HEAD_RESPONSE = 0.3
-- Manual neck seating, in studs. Negative pulls the head down onto the shoulders.
local NECK_SEAT = 0

-- Scale a CFrame's position per-axis, keep its rotation.
local function scaleOffset(cf: CFrame, axisScale: Vector3): CFrame
	local pos = cf.Position
	local newPos = Vector3.new(pos.X * axisScale.X, pos.Y * axisScale.Y, pos.Z * axisScale.Z)
	return CFrame.new(newPos) * (cf - pos)
end

local function getOrCreateVector3Value(parent: Instance, name: string, value: Vector3): Vector3
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Vector3Value") then
		return existing.Value
	end
	local v = Instance.new("Vector3Value")
	v.Name = name
	v.Value = value
	v.Parent = parent
	return value
end

local function getOrCreateCFrameValue(parent: Instance, name: string, value: CFrame): CFrame
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("CFrameValue") then
		return existing.Value
	end
	local v = Instance.new("CFrameValue")
	v.Name = name
	v.Value = value
	v.Parent = parent
	return value
end

-- Is `part` a hair accessory's part (its Handle, or a descendant of one)? Hair follows
-- the head's scale, not the full body ratio.
local function isHairPart(part: Instance): boolean
	local accessory = part:FindFirstAncestorWhichIsA("Accessory")
	return accessory ~= nil and accessory.AccessoryType == Enum.AccessoryType.Hair
end

function HeightHandler.resize(
	partsToResize: Instance | { Instance },
	ratio: Vector3,
	character: Model,
	accessoryMode: ("body" | "head")?,
	offsetOverride: { [string]: CloakOffset | {} }?
)
	local offsets = offsetOverride or gameHats

	local bodyScale = (ratio.X * ratio.Y * ratio.Z) ^ (1 / 3)
	local headFactor = 1 + (bodyScale - 1) * HEAD_RESPONSE
	local headScale = Vector3.new(headFactor, headFactor, headFactor)

	local function hatResize(part: Instance, forcedMode: ("body" | "head")?)
		local mode: "body" | "head" = forcedMode or (if offsets[part.Name] then "body" else "head")
		local accScale = if mode == "body" then ratio else headScale

		local acc: Instance
		if mode == "body" then
			acc = part
		else
			acc = part:Clone()
			acc.Parent = Lighting
			part:Destroy()
		end

		local hand = acc:WaitForChild("Handle")
		for _, child in hand:GetChildren() do
			if child.Name == "Mesh" or child:IsA("SpecialMesh") then
				local original = getOrCreateVector3Value(child, "OriginalScale", (child :: any).Scale)
				;(child :: any).Scale = original * accScale
			end
		end

		local meshPart = acc:FindFirstChildOfClass("MeshPart")
		if meshPart then
			local original = getOrCreateVector3Value(meshPart, "OriginalScale", meshPart.Size)
			meshPart.Size = original * accScale
		end

		if mode ~= "body" then
			acc.Parent = character
			local handle = acc:FindFirstChild("Handle")
			local weld = handle and handle:FindFirstChild("AccessoryWeld")
			if weld and weld:IsA("Weld") then
				weld.Part1 = character:WaitForChild("Head") :: BasePart
			end
		end

		local handle = acc:FindFirstChild("Handle")
		local weldInstance = handle and handle:FindFirstChild("AccessoryWeld")
		if weldInstance and weldInstance:IsA("JointInstance") then
			local weld = weldInstance
			if mode == "body" then
				local corr = offsets[acc.Name]
				if corr and (corr :: CloakOffset).pos then
					local cloakCorr = corr :: CloakOffset
					local scaledPos = Vector3.new(cloakCorr.pos.X * accScale.X, cloakCorr.pos.Y, cloakCorr.pos.Z * accScale.Z)
					local rot = CFrame.Angles(math.rad(cloakCorr.rot.X), math.rad(cloakCorr.rot.Y), math.rad(cloakCorr.rot.Z))
					weld.C0 = weld.C0 * CFrame.new(scaledPos) * rot

					local d = cloakCorr.drift
					local driftShift = Vector3.new((ratio.Y - 1) * d.X, (ratio.Y - 1) * d.Y, (ratio.Y - 1) * d.Z)
					weld.C0 = weld.C0 * CFrame.new(driftShift)
				end
			else
				local originalC0 = getOrCreateCFrameValue(weld, "OriginalC0", weld.C0)
				local originalC1 = getOrCreateCFrameValue(weld, "OriginalC1", weld.C1)
				weld.C0 = scaleOffset(originalC0, accScale)
				weld.C1 = scaleOffset(originalC1, accScale)
			end
		end
	end

	if typeof(partsToResize) ~= "table" then
		hatResize(partsToResize, accessoryMode)
		return
	end

	for _, part in partsToResize :: { Instance } do
		-- Hats/cloaks are resized through hatResize (called by ItemHandler.equip and
		-- AgeService's rebuildAccessories), not this generic pass.
		if part:IsA("Accessory") then
			continue
		end

		if part:IsA("BasePart") and part.Name ~= "Head" and part.Name ~= "FalseHead" then
			-- Hair follows the head's (smaller) scale, not the body's.
			local partRatio = if isHairPart(part) then headScale else ratio

			local originalSize = getOrCreateVector3Value(part, "OriginalSize", part.Size)
			part.Size = originalSize * partRatio

			-- Any DataModelMesh subclass (SpecialMesh, BlockMesh, FileMesh, CylinderMesh).
			local mesh = part:FindFirstChild("Mesh")
			if mesh and mesh:IsA("DataModelMesh") then
				local originalScale = getOrCreateVector3Value(mesh, "OriginalScale", mesh.Scale)
				mesh.Scale = originalScale * partRatio
			end

			for _, child in part:GetChildren() do
				if child:IsA("MeshPart") then
					local originalChildSize = getOrCreateVector3Value(child, "OriginalSize", child.Size)
					child.Size = originalChildSize * partRatio
				end
			end
		elseif (part:IsA("BasePart") or part:IsA("MeshPart")) and (part.Name == "Head" or part.Name == "FalseHead") then
			local basePart = part :: BasePart
			local originalSize = getOrCreateVector3Value(basePart, "OriginalSize", basePart.Size)
			basePart.Size = originalSize * headScale
		elseif part:IsA("JointInstance") then
			local joint = part
			local originalC0 = getOrCreateCFrameValue(joint, "OriginalC0", joint.C0)
			local originalC1 = getOrCreateCFrameValue(joint, "OriginalC1", joint.C1)

			-- A hair accessory's AccessoryWeld follows the head's scale too.
			if isHairPart(joint) then
				joint.C0 = scaleOffset(originalC0, headScale)
				joint.C1 = scaleOffset(originalC1, headScale)
			elseif joint.Name:find("Neck") then
				joint.C0 = scaleOffset(originalC0, Vector3.new(1, ratio.Y, 1)) + Vector3.new(0, NECK_SEAT, 0)
				joint.C1 = scaleOffset(originalC1, headScale)
			else
				joint.C0 = scaleOffset(originalC0, ratio)
				joint.C1 = scaleOffset(originalC1, ratio)
			end
		elseif part:IsA("Attachment") and not part:FindFirstAncestor("Head") and not part:FindFirstAncestor("FalseHead") then
			local attachment = part
			-- Same as the joint branch above.
			local attachmentRatio = if isHairPart(attachment) then headScale else ratio
			local originalPosition = getOrCreateVector3Value(attachment, "OriginalPosition", attachment.Position)
			attachment.Position = originalPosition * attachmentRatio
		end
	end
end

return HeightHandler
