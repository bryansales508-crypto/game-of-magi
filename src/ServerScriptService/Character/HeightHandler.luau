local module = {}

local gameHats = {
	["Torn Cloak"] = { pos = Vector3.new(0, 0.3, -0.05), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 2, .25) },
	["Super Torn Cloak"] = { pos = Vector3.new(0, -0.15, -0.275), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 1.75, .25) },
	["Shoulder Cloth"] = { pos = Vector3.new(-1.375, 0.4, 0.05), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 0.25, 0) },
	["Shoulder Cloak"] = { pos = Vector3.new(.38, -0.1, 0), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 1.75, 0) },
	["Short Wrap"] = { pos = Vector3.new(-.175, 0, 0), rot = Vector3.new(0, 180, 5), drift = Vector3.new(0, 0.5, .1) },
	["Short Shoulder Cloak"] = { pos = Vector3.new(1.45, 0.4, 0.03), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 0.5, 0) },
	["Ripped Bandana"] = { pos = Vector3.new(0, -0.3, -.15), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 1.25, .25) },
	["Proper Cloak"] = { pos = Vector3.new(-0.05, -0.009, 0), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, .4, 0) },
	["Low Bandana"] = { pos = Vector3.new(0, -.5, .1), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 0.4, 0) },
	["Long Wrap"] = { pos = Vector3.new(0, .25, -0.25), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 1.2, 0) },
	["Long Scarf"] = { pos = Vector3.new(0, -.1, 0.05), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 1.125, 0) },
	["Full Shoulder Cloak"] = { pos = Vector3.new(0, -.18, -0.475), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 1.5, 0) },
	["Flamboyant Scarf"] = { pos = Vector3.new(0, -.3, 0), rot = Vector3.new(0, 0, 0), drift = Vector3.new(0, 2, .25) },
	["Fancy Shawl"] = { pos = Vector3.new(0, 0, .025), rot = Vector3.new(0, 180, 0), drift = Vector3.new(0, 1, 0.25) },
}

for _,gHat in game.ReplicatedFirst.Assets:GetChildren() do
	if gameHats[gHat.Name] == nil then
		gameHats[gHat.Name] = {}
	end
end

-- height: 1 = normal, >1 = taller, <1 = shorter
-- skinniness: 0 = no width change (pure stretch), 0.5 = volume-preserving (natural), 1 = aggressive
function module.heightToRatio(height, skinniness)
	skinniness = skinniness or 0.5
	local width = height ^ (-skinniness)
	return Vector3.new(width, height, width)
end

function module.isGameHat(name)
	return gameHats[name] ~= nil
end

-- How much the head (and hats) respond to overall body size. 1 = full, 0 = never.
local HEAD_RESPONSE = 0.3
-- Manual neck seating, in studs. Negative pulls the head down onto the shoulders.
local NECK_SEAT = 0

-- Scale a CFrame's position per-axis, keep its rotation.
local function scaleOffset(cf, axisScale)
	local pos = cf.Position
	local newPos = Vector3.new(pos.X * axisScale.X, pos.Y * axisScale.Y, pos.Z * axisScale.Z)
	return CFrame.new(newPos) * (cf - pos)
end

module.resize = function(partsToResize, ratio, chara, accessoryMode, offsetOverride)
	local offsets = offsetOverride or gameHats

	local bodyScale = (ratio.X * ratio.Y * ratio.Z) ^ (1/3)
	local headFactor = 1 + (bodyScale - 1) * HEAD_RESPONSE
	local headScale = Vector3.new(headFactor, headFactor, headFactor)

	local function hatResize(part, forcedMode)
		local mode = forcedMode or (offsets[part.Name] and "body" or "head")
		local accScale = (mode == "body") and ratio or headScale

		local acc
		if mode == "body" then
			acc = part
		else
			acc = part:Clone()
			acc.Parent = game.Lighting
			part:Destroy()
		end

		-- scale SpecialMesh accessories
		local hand = acc:WaitForChild("Handle")
		for _, childPart in hand:GetChildren() do
			if childPart.Name == "Mesh" or childPart:IsA("SpecialMesh") then
				if not childPart:FindFirstChild("OriginalScale") then
					local o = Instance.new("Vector3Value")
					o.Name = "OriginalScale"; o.Value = childPart.Scale; o.Parent = childPart
				end
				childPart.Scale = childPart.OriginalScale.Value * accScale
			end
		end

		-- scale MeshPart accessories
		local meshPart = acc:FindFirstChildOfClass("MeshPart")
		if meshPart then
			if not meshPart:FindFirstChild("OriginalScale") then
				local o = Instance.new("Vector3Value")
				o.Name = "OriginalScale"; o.Value = meshPart.Size; o.Parent = meshPart
			end
			meshPart.Size = meshPart.OriginalScale.Value * accScale
		end

		-- hats need parenting + head re-weld; cloaks are already parented & welded
		if mode ~= "body" then
			acc.Parent = chara
			if acc.Handle:FindFirstChild("AccessoryWeld") then
				acc.Handle.AccessoryWeld.Part1 = chara:WaitForChild("Head")
			end
		end

		local weld = acc.Handle:FindFirstChild("AccessoryWeld")
		if weld then
			if mode == "body" then
				local corr = offsets[acc.Name]
				if corr then
					local scaledPos = Vector3.new(
						corr.pos.X * accScale.X,
						corr.pos.Y,
						corr.pos.Z * accScale.Z
					)
					local rot = CFrame.Angles(
						math.rad(corr.rot.X), math.rad(corr.rot.Y), math.rad(corr.rot.Z)
					)
					weld.C0 = weld.C0 * CFrame.new(scaledPos) * rot

					local d = corr.drift or Vector3.new(0, 0, 0)
					local driftShift = Vector3.new(
						(ratio.Y - 1) * d.X,
						(ratio.Y - 1) * d.Y,
						(ratio.Y - 1) * d.Z
					)
					weld.C0 = weld.C0 * CFrame.new(driftShift)
				end
			else
				-- HAT: capture clean original, then scale weld to follow the head
				if not weld:FindFirstChild("OriginalC0") then
					local c0 = Instance.new("CFrameValue")
					c0.Name = "OriginalC0"; c0.Value = weld.C0; c0.Parent = weld
				end
				if not weld:FindFirstChild("OriginalC1") then
					local c1 = Instance.new("CFrameValue")
					c1.Name = "OriginalC1"; c1.Value = weld.C1; c1.Parent = weld
				end
				weld.C0 = scaleOffset(weld.OriginalC0.Value, accScale)
				weld.C1 = scaleOffset(weld.OriginalC1.Value, accScale)
			end
		end
	end

	if type(partsToResize) ~= "table" then
		hatResize(partsToResize, accessoryMode)
		return
	end

	for _, part in ipairs(partsToResize) do
		if part:IsA("Accessory") then
			--[[if module.isGameHat(part.Name) then
				hatResize(part)
			end]]

		elseif part:IsA("BasePart") and part.Name ~= "Head" and part.Name ~= "FalseHead" then
			if not part:FindFirstChild("OriginalSize") then
				local o = Instance.new("Vector3Value")
				o.Name = "OriginalSize"; o.Value = part.Size; o.Parent = part
			end
			part.Size = part.OriginalSize.Value * ratio

			if part:FindFirstChild("Mesh") then
				local m = part.Mesh
				if not m:FindFirstChild("OriginalScale") then
					local o = Instance.new("Vector3Value")
					o.Name = "OriginalScale"; o.Value = m.Scale; o.Parent = m
				end
				m.Scale = m.OriginalScale.Value * ratio
			end

			for _, v in part:GetChildren() do
				if v:IsA("MeshPart") then
					if not v:FindFirstChild("OriginalSize") then
						local o = Instance.new("Vector3Value")
						o.Name = "OriginalSize"; o.Value = v.Size; o.Parent = v
					end
					v.Size = v.OriginalSize.Value * ratio
				end
			end

		elseif (part:IsA("BasePart") or part:IsA("MeshPart")) and (part.Name == "Head" or part.Name == "FalseHead") then
			if not part:FindFirstChild("OriginalSize") then
				local o = Instance.new("Vector3Value")
				o.Name = "OriginalSize"; o.Value = part.Size; o.Parent = part
			end
			part.Size = part.OriginalSize.Value * headScale

		elseif part:IsA("JointInstance") then
			local joint = part
			if not joint:FindFirstChild("OriginalC0") then
				local c0 = Instance.new("CFrameValue")
				c0.Name = "OriginalC0"; c0.Value = joint.C0; c0.Parent = joint
			end
			if not joint:FindFirstChild("OriginalC1") then
				local c1 = Instance.new("CFrameValue")
				c1.Name = "OriginalC1"; c1.Value = joint.C1; c1.Parent = joint
			end

			if joint.Name:find("Neck") then
				joint.C0 = scaleOffset(joint.OriginalC0.Value, Vector3.new(1, ratio.Y, 1))
					+ Vector3.new(0, NECK_SEAT, 0)
				joint.C1 = scaleOffset(joint.OriginalC1.Value, headScale)
			else
				joint.C0 = scaleOffset(joint.OriginalC0.Value, ratio)
				joint.C1 = scaleOffset(joint.OriginalC1.Value, ratio)
			end

		elseif part:IsA("Attachment") and not part:FindFirstAncestor("Head") and not part:FindFirstAncestor("FalseHead") then
			local v = part
			if not v:FindFirstChild("OriginalPosition") then
				local o = Instance.new("Vector3Value")
				o.Name = "OriginalPosition"; o.Value = v.Position; o.Parent = v
			end
			v.Position = v.OriginalPosition.Value * ratio
		end
	end
end

return module