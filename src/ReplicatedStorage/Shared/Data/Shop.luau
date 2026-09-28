--!strict
-- The Qarzin clothes stand (M5-PLAN.md Phase 5B, Bryan's rules 2026-09-29).
-- Pure data: no Player, no save, no remotes, no Workspace access - ShopService
-- is the only thing that touches the stand's actual Instances or a wallet.
--
-- Ported from the old Studio-only Workspace.Qarzin.ClothesStand.ClothingSpawn
-- (docs/reference/m5b-studio-dump.md): same colour pools/weights, the same
-- hat/cloak/shirt/pants pools (read from ReplicatedFirst.Assets, the single
-- source of truth, instead of a second copy of the names), the same display
-- rotations/offsets, and the same prices - only "Gold" is renamed "Tan"
-- (identical RGB) and prices are now base copper values shown through the
-- 5A band rule (Shared/Data/Economy.luau) instead of the old module's own
-- (buggy) copper/silver/gold split.

local ReplicatedFirst = game:GetService("ReplicatedFirst")
local Assets = require(ReplicatedFirst.Assets) :: any

local Shop = {}

export type ItemType = "S" | "P" | "H" | "C"

export type ShopColor = {
	name: string,
	color: Color3,
	weight: number,
	priceMult: number?,
}

export type ClothingItem = {
	id: string,
	name: string,
	forSale: boolean,
}

export type CloakStandOffset = {
	pos: Vector3,
	extraRotY: number?, -- degrees, applied after pos
}

-- ==================== the stand's parts (Workspace, not synced - names only, see docs/reference/m5b-studio-dump.md #1) ====================

Shop.WorkspacePath = "Qarzin.ClothesStand" -- Workspace.Qarzin.ClothesStand
Shop.StudioScriptName = "ClothingSpawn" -- disabled at ShopService:Init(); Bryan deletes it once this phase passes

Shop.HatTableName = "HatTable"
Shop.HeadHolderName = "HeadHolder" -- x8, invisible anchors under HatTable

Shop.OutfitTableName = "OutfitTable"
Shop.ClothingRackName = "ClothingRack" -- x9 dummy rigs under OutfitTable
Shop.ShirtHLName = "ShirtHL" -- hover/purchase spot on a rack
Shop.PantsHLName = "PantsHL"

Shop.StandTableName = "StandTable"
Shop.CloakHolderName = "CloakHolder" -- x3, invisible anchors under StandTable

-- ==================== prompts ====================

Shop.HoldDuration = 2
-- The pants prompt has always shown this fixed name instead of the pool
-- item's real name (today just "Standard") - an old MarketHandler quirk,
-- kept on purpose (Bryan: keep the stand's behaviour exactly as it was).
Shop.PantsDisplayName = "Harem Pants"
Shop.StockDelaySeconds = 5

-- ==================== colour pools ====================
-- Standard: hats, cloaks and pants roll from this pool. Variety: shirts
-- only. "Gold" -> "Tan" (Bryan 2026-09-29), same RGB (230,210,129).

Shop.StandardColors = {
	{ name = "White", color = Color3.fromRGB(255, 255, 255), weight = 80 } :: ShopColor,
	{ name = "Tan", color = Color3.fromRGB(230, 210, 129), weight = 25, priceMult = 1.25 } :: ShopColor,
	{ name = "Black", color = Color3.fromRGB(35, 35, 35), weight = 10, priceMult = 1.5 } :: ShopColor,
}

Shop.VarietyColors = {
	{ name = "Red", color = Color3.fromRGB(175, 42, 42), weight = 10 } :: ShopColor,
	{ name = "Blue", color = Color3.fromRGB(131, 170, 255), weight = 10 } :: ShopColor,
	{ name = "Green", color = Color3.fromRGB(80, 198, 71), weight = 10 } :: ShopColor,
	{ name = "Yellow", color = Color3.fromRGB(255, 204, 0), weight = 10 } :: ShopColor,
	{ name = "Purple", color = Color3.fromRGB(170, 85, 255), weight = 10 } :: ShopColor,
	{ name = "Orange", color = Color3.fromRGB(255, 85, 0), weight = 10 } :: ShopColor,
	{ name = "Pink", color = Color3.fromRGB(255, 126, 199), weight = 10 } :: ShopColor,
	{ name = "Brown", color = Color3.fromRGB(131, 82, 39), weight = 10 } :: ShopColor,
	{ name = "Turquoise", color = Color3.fromRGB(54, 216, 183), weight = 10 } :: ShopColor,
	{ name = "Black", color = Color3.fromRGB(53, 53, 53), weight = 10 } :: ShopColor,
	{ name = "White", color = Color3.fromRGB(199, 199, 199), weight = 10 } :: ShopColor,
}

-- Weighted roll. `roll` is 1..totalWeight; passed explicitly by the
-- self-test for a deterministic pick, otherwise a fresh math.random.
function Shop.RollColor(pool: { ShopColor }, roll: number?): ShopColor
	local total = 0
	for _, c in pool do
		total += c.weight
	end
	local r = roll or math.random(1, total)
	local acc = 0
	for _, c in pool do
		acc += c.weight
		if r <= acc then
			return c
		end
	end
	return pool[#pool]
end

-- ==================== prices ====================
-- The old MarketHandler.GetPrice("Qarzin", "Clothing", colour, itemType)
-- numbers (docs/reference/m5b-studio-dump.md #4, MISC/MarketHandler.luau,
-- now deleted): Qarzin's Clothing resource was base 80, demand/supply both
-- 10 (ratio 1, "throttle prevention" no-op); hats got *1.2, cloaks *1.5,
-- shirts/pants no type multiplier; then the rolled colour's own PriceMult
-- on top, ceil'd once at the end - priceTag = ceil(80 * typeMult * colorMult).
-- Every one of those numbers was already under the old module's own 1,000
-- split point, so it always displayed as that many raw Copper; these ARE
-- that same copper number, just moved into data - today's effective prices
-- are unchanged, only Shared/Data/Economy.luau's band rule now decides which
-- coin it shows in.
Shop.ClothingBaseCopper = 80
Shop.TypeMult = {
	H = 1.2,
	C = 1.5,
	S = 1,
	P = 1,
} :: { [ItemType]: number }

function Shop.PriceFor(itemType: ItemType, color: ShopColor): number
	local mult = color.priceMult or 1
	return math.ceil(Shop.ClothingBaseCopper * Shop.TypeMult[itemType] * mult)
end

-- ==================== hats and cloaks (names from Assets) ====================

Shop.HatNames = Assets.hats.head :: { string } -- 8 names
Shop.CloakNames = Assets.cloaks :: { string } -- 14 names

-- Display rotation fixes on top of the holder's own CFrame (docs dump #2).
Shop.HatRotationFix = {
	["Short Covering"] = CFrame.Angles(0, math.rad(180), 0),
	["Cowl"] = CFrame.Angles(0, math.rad(180), 0),
	["Feather"] = CFrame.Angles(math.rad(-25), math.rad(45), math.rad(90)) * CFrame.new(-0.25, 0, 0),
} :: { [string]: CFrame }

-- Every cloak sits at Holder.CFrame * CFrame.new(0,-1.5,0) * CFrame.Angles(0,180,0)
-- (applied by ShopService) plus this per-cloak position offset, and for two
-- of them (Flamboyant Scarf, Short Wrap) an extra Y rotation after that.
Shop.CloakOffsets = {
	["Super Torn Cloak"] = { pos = Vector3.new(-0.8, -0.3, 0.25) } :: CloakStandOffset,
	["Torn Cloak"] = { pos = Vector3.new(0.1, -0.5, 0.5) } :: CloakStandOffset,
	["Long Wrap"] = { pos = Vector3.new(0, 0.35, 0) } :: CloakStandOffset,
	["Flamboyant Scarf"] = { pos = Vector3.new(0, -0.2, 0.9), extraRotY = 180 } :: CloakStandOffset,
	["Proper Cloak"] = { pos = Vector3.new(0, 1, 0.05) } :: CloakStandOffset,
	["Shoulder Cloak"] = { pos = Vector3.new(0, -0.534, 0) } :: CloakStandOffset,
	["Ripped Bandana"] = { pos = Vector3.new(0, 0.275, 0) } :: CloakStandOffset,
	["Low Bandana"] = { pos = Vector3.new(0, 1, 0) } :: CloakStandOffset,
	["Long Scarf"] = { pos = Vector3.new(0, 0.325, 0.2) } :: CloakStandOffset,
	["Full Shoulder Cloak"] = { pos = Vector3.new(0.55, 0, 0.2) } :: CloakStandOffset,
	["Fancy Shawl"] = { pos = Vector3.new(0, 0.5, 0.1) } :: CloakStandOffset,
	["Short Wrap"] = { pos = Vector3.new(0, 1.15, 0.1), extraRotY = 90 } :: CloakStandOffset,
	["Shoulder Cloth"] = { pos = Vector3.new(1.5, 1.2, 0) } :: CloakStandOffset,
	["Short Shoulder Cloak"] = { pos = Vector3.new(-1.5, 1, 0) } :: CloakStandOffset,
} :: { [string]: CloakStandOffset }

-- ==================== shirts and pants (from Assets.outfits.desertBasic) ====================
-- The starter rags (Short Sleeve Rags / Shoes and Rags / Barefooted and
-- Rags) stay out of the shop on purpose - forSale = false, not a separate
-- pool, so the full desertBasic list stays the one source of truth and a
-- new item only ever needs adding once, in Assets.

local RAG_NAMES: { [string]: boolean } = {
	["Short Sleeve Rags"] = true,
	["Shoes and Rags"] = true,
	["Barefooted and Rags"] = true,
}

local function buildPool(entries: { { id: string, name: string } }): { ClothingItem }
	local pool: { ClothingItem } = {}
	for _, entry in entries do
		table.insert(pool, { id = entry.id, name = entry.name, forSale = not RAG_NAMES[entry.name] })
	end
	return pool
end

Shop.Shirts = buildPool(Assets.outfits.desertBasic.shirt) :: { ClothingItem }
-- Today this pool has exactly one for-sale entry ("Standard") - Bryan's
-- rule is that the DATA has room for more designs later, not that the code
-- only ever expects one; ShopService and this pool never hardcode "1".
Shop.Pants = buildPool(Assets.outfits.desertBasic.pants) :: { ClothingItem }

function Shop.ForSale(pool: { ClothingItem }): { ClothingItem }
	local out: { ClothingItem } = {}
	for _, item in pool do
		if item.forSale then
			table.insert(out, item)
		end
	end
	return out
end

-- ==================== stocking amounts ====================
-- "random(#spots/3, #spots)" (docs dump #2), floored for integer safety
-- (math.random needs integer bounds) and never below 1.

function Shop.StockRange(spotCount: number): (number, number)
	return math.max(1, spotCount // 3), spotCount
end

table.freeze(Shop.TypeMult)
table.freeze(Shop.HatRotationFix)
for _, offset in Shop.CloakOffsets do
	table.freeze(offset)
end
table.freeze(Shop.CloakOffsets)
for _, color in Shop.StandardColors do
	table.freeze(color)
end
table.freeze(Shop.StandardColors)
for _, color in Shop.VarietyColors do
	table.freeze(color)
end
table.freeze(Shop.VarietyColors)
for _, item in Shop.Shirts do
	table.freeze(item)
end
table.freeze(Shop.Shirts)
for _, item in Shop.Pants do
	table.freeze(item)
end
table.freeze(Shop.Pants)
table.freeze(Shop)

return Shop
