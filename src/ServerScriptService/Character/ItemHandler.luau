-- ServerScriptService.Character.ItemHandler
local ItemHandler = {}

local assets = require(game.ReplicatedFirst.Assets)
local hm     = require(game.ServerScriptService.Character.HeightHandler)
local ageHandle = require(game.ServerScriptService.Character.AgeHandler)

-- ===== color <-> string ("255,210,129") =====
local function colorToCode(c)
	return ("%d,%d,%d"):format(
		math.round(c.R * 255), math.round(c.G * 255), math.round(c.B * 255)
	)
end

local function codeToColor(s)
	local r, g, b = tostring(s):match("(%d+),(%d+),(%d+)")
	if not r then return Color3.new(1, 1, 1) end  -- fallback white on bad data
	return Color3.fromRGB(tonumber(r), tonumber(g), tonumber(b))
end

ItemHandler.colorToCode = colorToCode  -- expose so the shop can encode a rolled color

-- ===== code format: "type|name|r,g,b"  e.g. "C|Torn Cloak|255,210,129" =====
function ItemHandler.encode(itemType, name, colorCode)
	return table.concat({itemType, name, colorCode or "255,255,255"}, "|")
end

function ItemHandler.decode(code)
	if type(code) ~= "string" then return nil end
	local p = code:split("|")
	if #p < 3 then return nil end
	return p[1], p[2], p[3]   -- type, name, "r,g,b"
end

local function currentRatio(player)
	local stats = player.Stats
	local profile = ageHandle.unpack(stats.GrowthProfile.Value)
	local fat = profile and ageHandle.fatAt(profile, stats.Age.Value) or 0
	return hm.heightToRatio(stats.Height.Value, fat)
end

local outfits = assets.outfits.desertBasic

function ItemHandler.clothingId(itemType, name)
	local list = (itemType == "S") and outfits.shirt or outfits.pants
	for _, entry in list do
		if entry.name == name then return entry.id end
	end
	return nil
end

function ItemHandler.equip(code, chara)
	local itemType, name, colorCode = ItemHandler.decode(code)
	if not itemType then return end
	local player = game.Players:GetPlayerFromCharacter(chara)
	if not player then return end

	-- CLOTHING (pants and shirts)
	if itemType == "S" or itemType == "P" then
		local id = ItemHandler.clothingId(itemType, name)
		if not id then warn("ItemHandler: no clothing", name); return end
		local color = codeToColor(colorCode)

		if itemType == "S" then
			local shirt = chara:FindFirstChildOfClass("Shirt") or Instance.new("Shirt", chara)
			shirt.ShirtTemplate = id
			shirt.Color3 = color
		else
			local pants = chara:FindFirstChildOfClass("Pants") or Instance.new("Pants", chara)
			pants.PantsTemplate = id
			pants.Color3 = color
		end
		return
	end

	-- ACCESSORIES (hats and cloaks)
	local asset = game.ReplicatedFirst.Assets:FindFirstChild(name)
	if not asset then warn("ItemHandler: no asset named", name); return end
	local item = asset:Clone()
	item.Handle.Transparency = 1
	local mp = item:FindFirstChildOfClass("MeshPart")
	if mp then mp.Color = codeToColor(colorCode) end
	
	local att = item.Handle:FindFirstChildOfClass("Attachment")
	chara.Humanoid:AddAccessory(item)
	item.Handle:WaitForChild("AccessoryWeld", 5)
	task.wait()

	if itemType == "C" then
		if att then att.CFrame = att.CFrame * CFrame.Angles(0, math.rad(180), 0) end
		hm.resize(item, currentRatio(player), chara, "body")
	else
		hm.resize(item, currentRatio(player), chara, "head")
	end
	return item
end

return ItemHandler