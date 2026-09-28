--!strict
-- Wearables: item codes ("type|name|r,g,b"), equip (recolour + resize to
-- the current body, exactly as before), colour-aware ownership, and writing
-- a worn item into the save. Ported from the old
-- ServerScriptService.Character.ItemHandler (M5-PLAN.md Phase 5B) - same
-- code format and equip behaviour; only the typing changed and two things
-- were added: Owns (exact item AND colour - the old MarketHandler ignored
-- colour) and Wear (equips, then writes Gear.Shirt/Gear.Pants/the first
-- empty Gear.Hats slot).

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local SaveSchema = require(ReplicatedStorage.Shared.SaveSchema)
local Assets = require(ReplicatedFirst.Assets) :: any
local HeightHandler = require(script.Parent.AgeService.HeightHandler)
local AgeHandler = require(script.Parent.AgeService.AgeHandler)
local DataService = require(script.Parent.DataService)

local log = Log.new("ItemService")

type Data = SaveSchema.Data

export type ItemType = "S" | "P" | "H" | "C"

local ItemService = {}

-- ==================== code format: "type|name|r,g,b" (pure, self-tested directly) ====================

local function colorToCode(c: Color3): string
	return string.format("%d,%d,%d", math.round(c.R * 255), math.round(c.G * 255), math.round(c.B * 255))
end

local function codeToColor(s: string): Color3
	local r, g, b = s:match("(%d+),(%d+),(%d+)")
	if not r then
		return Color3.new(1, 1, 1) -- fallback white on bad data, same as before
	end
	return Color3.fromRGB(tonumber(r) :: number, tonumber(g) :: number, tonumber(b) :: number)
end

ItemService.ColorToCode = colorToCode -- exposed so the shop can encode a rolled colour

function ItemService.Encode(itemType: string, name: string, colorCode: string?): string
	return table.concat({ itemType, name, colorCode or "255,255,255" }, "|")
end

function ItemService.Decode(code: string): (string?, string?, string?)
	if type(code) ~= "string" then
		return nil
	end
	local p = code:split("|")
	if #p < 3 then
		return nil
	end
	return p[1], p[2], p[3] -- type, name, "r,g,b"
end

local outfits = Assets.outfits.desertBasic

function ItemService.ClothingId(itemType: string, name: string): string?
	local list = if itemType == "S" then outfits.shirt else outfits.pants
	for _, entry in list do
		if entry.name == name then
			return entry.id
		end
	end
	return nil
end

-- Pure: whether `data` already holds the exact item AND colour `code`
-- names - Owns distinguishes colour on purpose (REVIEW/AUDIT: the old
-- MarketHandler only compared the clothing id, so owning a black shirt
-- blocked buying an identical white one; a hat/cloak match was already
-- colour-aware there, this just makes shirts/pants consistent with it).
function ItemService.Owns(data: Data, code: string): boolean
	local itemType = ItemService.Decode(code)
	if itemType == nil then
		return false
	end
	if itemType == "S" then
		return data.Gear.Shirt == code
	elseif itemType == "P" then
		return data.Gear.Pants == code
	end
	for _, hatCode in data.Gear.Hats do
		if hatCode == code then
			return true
		end
	end
	return false
end

-- Pure: the 3-slot Gear.Hats array holds both hats AND cloaks (same as the
-- save alone; nothing mirrors it since M6) - checked before EconomyService.Pay
-- ever runs, not after.
function ItemService.HasFreeHatSlot(data: Data): boolean
	for _, hatCode in data.Gear.Hats do
		if hatCode == "" then
			return true
		end
	end
	return false
end

local function currentRatio(player: Player): Vector3
	local data = DataService.Get(player)
	if data == nil then
		return Vector3.new(1, 1, 1)
	end
	local profile = AgeHandler.unpack(data.Character.GrowthProfile)
	local fat = if profile then AgeHandler.fatAt(profile, data.Age.Years) else 0
	return HeightHandler.heightToRatio(data.Character.Height, fat)
end

-- Equips `code` onto `chara`: recolours a shirt/pants in place, or clones
-- and resizes a hat/cloak accessory to the wearer's current body - same
-- behaviour as the old ItemHandler.equip.
function ItemService.Equip(code: string, chara: Model): Instance?
	local itemType, name, colorCode = ItemService.Decode(code)
	if itemType == nil or name == nil then
		return nil
	end
	local player = Players:GetPlayerFromCharacter(chara)
	if player == nil then
		return nil
	end
	local color = codeToColor(colorCode or "255,255,255")

	if itemType == "S" or itemType == "P" then
		local id = ItemService.ClothingId(itemType, name :: string)
		if id == nil then
			log:Warn(string.format("no clothing id for %s %q", itemType, name))
			return nil
		end
		if itemType == "S" then
			local shirt = (chara:FindFirstChildOfClass("Shirt") :: Shirt?) or Instance.new("Shirt")
			shirt.ShirtTemplate = id
			shirt.Color3 = color
			shirt.Parent = chara
		else
			local pants = (chara:FindFirstChildOfClass("Pants") :: Pants?) or Instance.new("Pants")
			pants.PantsTemplate = id
			pants.Color3 = color
			pants.Parent = chara
		end
		return nil
	end

	local asset = ReplicatedFirst.Assets:FindFirstChild(name :: string)
	if asset == nil then
		log:Warn(string.format("no asset named %q", name))
		return nil
	end
	local item = asset:Clone()
	local handle = item:FindFirstChild("Handle")
	if handle == nil or not handle:IsA("BasePart") then
		item:Destroy()
		return nil
	end
	handle.Transparency = 1
	local meshPart = item:FindFirstChildOfClass("MeshPart")
	if meshPart then
		meshPart.Color = color
	end
	local attachment = handle:FindFirstChildOfClass("Attachment")

	local humanoid = chara:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		item:Destroy()
		return nil
	end
	humanoid:AddAccessory(item :: Accessory)
	handle:WaitForChild("AccessoryWeld", 5)
	task.wait()

	if itemType == "C" then
		if attachment then
			attachment.CFrame = attachment.CFrame * CFrame.Angles(0, math.rad(180), 0)
		end
		HeightHandler.resize(item, currentRatio(player), chara, "body")
	else
		HeightHandler.resize(item, currentRatio(player), chara, "head")
	end
	return item
end

-- Equips `code` onto the player's current character AND writes it into the
-- save: Gear.Shirt/Gear.Pants for S/P, or the first empty Gear.Hats slot for
-- H/C. The slot-free check is the CALLER's job (ShopService checks it
-- before ever charging) - this repeats it as a second guard, the same
-- defense-in-depth every other write path in this codebase uses, not the
-- only place it's enforced. Returns false (nothing charged back, nothing
-- written) if there's no free slot or no character to equip onto.
function ItemService.Wear(player: Player, code: string): boolean
	local itemType = ItemService.Decode(code)
	if itemType == nil then
		return false
	end
	local character = player.Character
	if character == nil then
		return false
	end
	local data = DataService.Get(player)
	if data == nil then
		return false
	end

	if itemType == "S" then
		data.Gear.Shirt = code
	elseif itemType == "P" then
		data.Gear.Pants = code
	else
		local slot: number? = nil
		for i, hatCode in data.Gear.Hats do
			if hatCode == "" then
				slot = i
				break
			end
		end
		if slot == nil then
			return false
		end
		data.Gear.Hats[slot] = code
	end

	ItemService.Equip(code, character)
	return true
end

return ItemService
