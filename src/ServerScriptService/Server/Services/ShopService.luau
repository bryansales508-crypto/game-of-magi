--!strict
-- The Qarzin clothes stand, in synced code (M5-PLAN.md Phase 5B, Bryan's
-- rules 2026-09-29). Replaces the Studio-only
-- Workspace.Qarzin.ClothesStand.ClothingSpawn script (disabled at Init,
-- Bryan deletes it once this phase passes) - same stock, look and
-- randomness as that script (docs/reference/m5b-studio-dump.md), moved into
-- Shared/Data/Shop.luau + this service, purchases through
-- EconomyService.Pay and ItemService.Wear instead of the old MarketHandler/
-- OnCharacter.Currency.
--
-- The hover highlight is client-only now (M5B's ShopController, a separate
-- client task): the server never enables the rig's Highlight and never
-- toggles the *HL parts' transparency - every prompt just stays Enabled,
-- RequiresLineOfSight = false, so a client can decide locally (e.g. a mouse
-- raycast against the always-present *HL part) whose highlight to show.
--
-- Stocking runs once per server, StockDelaySeconds after Start (same delay
-- the old script used) - no per-frame loop anywhere in this file. Every
-- ProximityPrompt connection this service makes is tracked in
-- `connections`; `.shop restock` disconnects and destroys everything before
-- stocking again.

local Workspace = game:GetService("Workspace")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local SaveSchema = require(ReplicatedStorage.Shared.SaveSchema)
local Economy = require(ReplicatedStorage.Shared.Data.Economy)
local Shop = require(ReplicatedStorage.Shared.Data.Shop)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local ItemService = require(script.Parent.ItemService)
local DevService = require(script.Parent.DevService)

local log = Log.new("ShopService")

type Data = SaveSchema.Data
type ShopColor = Shop.ShopColor
type ClothingItem = Shop.ClothingItem
type ItemType = Shop.ItemType
type Coin = Economy.Coin

local ShopService = {}

-- ==================== pure decision core (self-tested directly) ====================

export type PurchaseDecision = "ok" | "slotsFull" | "owned"

-- Pure: every check that must pass BEFORE EconomyService.Pay is ever
-- called - slot capacity (hats and cloaks share the same 3-slot
-- Gear.Hats), then exact item+colour ownership. Affordability is checked
-- last, inside EconomyService.Pay itself (it already fires the right
-- flavour line on failure), so this never duplicates that check.
function ShopService.Decide(data: Data, itemType: ItemType, code: string): PurchaseDecision
	if (itemType == "H" or itemType == "C") and not ItemService.HasFreeHatSlot(data) then
		return "slotsFull"
	end
	if ItemService.Owns(data, code) then
		return "owned"
	end
	return "ok"
end

-- ==================== flavour lines (old MarketHandler pools not covered by EconomyService) ====================
-- NeedMoney/Convert are EconomyService.Pay's job (SYSTEMS.md section 6).
-- These two are shop-specific: full hat/cloak inventory, and "I already
-- have this".

local MAX_CAPACITY_LINES = {
	"I don't have enough room...",
	"I need to go store something...",
}

local MATCH_LINES = {
	"Didn't I buy this?",
	"Don't I have this already...",
	"I legit have this on.",
}

local function fireFlavour(player: Player, pool: { string })
	Remotes.Server.Fire("CoinMessage", player, pool[math.random(1, #pool)])
end

-- ==================== stand lookup ====================

local function getStand(): Instance?
	local qarzin = Workspace:FindFirstChild("Qarzin")
	if qarzin == nil then
		return nil
	end
	return qarzin:FindFirstChild("ClothesStand")
end

local function childrenNamed(parent: Instance?, name: string, className: string): { Instance }
	local out: { Instance } = {}
	if parent == nil then
		return out
	end
	for _, child in parent:GetChildren() do
		if child.Name == name and (className == "" or child:IsA(className :: any)) then
			table.insert(out, child)
		end
	end
	return out
end

local function shuffled<T>(list: { T }): { T }
	local out = table.clone(list)
	for i = #out, 2, -1 do
		local j = math.random(1, i)
		out[i], out[j] = out[j], out[i]
	end
	return out
end

-- ==================== tracked stand state ====================
-- Rebuilt from scratch on every stock/restock; cleared first so a restock
-- never leaks a connection, a cloned mesh, or a stale listing.

type Listing = { itemType: ItemType, name: string, colorName: string, price: number }

local connections: { RBXScriptConnection } = {}
local trackedInstances: { Instance } = {}
local dressedRacks: { Model } = {}
local currentListings: { Listing } = {}

local function clearStock()
	for _, conn in connections do
		conn:Disconnect()
	end
	table.clear(connections)

	for _, inst in trackedInstances do
		if inst.Parent then
			inst:Destroy()
		end
	end
	table.clear(trackedInstances)

	for _, rack in dressedRacks do
		for _, part in rack:GetDescendants() do
			if
				part:IsA("BasePart")
				and part.Name ~= "HumanoidRootPart"
				and part.Name ~= Shop.ShirtHLName
				and part.Name ~= Shop.PantsHLName
			then
				part.Transparency = 1
			end
		end
		local shirt = rack:FindFirstChildOfClass("Shirt")
		if shirt then
			shirt.ShirtTemplate = ""
		end
		local pants = rack:FindFirstChildOfClass("Pants")
		if pants then
			pants.PantsTemplate = ""
		end
	end
	table.clear(dressedRacks)
	table.clear(currentListings)
end

-- ==================== purchase wiring ====================

local function createPrompt(parent: Instance, objectText: string, price: number, clickable: boolean): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.HoldDuration = Shop.HoldDuration
	prompt.ObjectText = objectText
	-- Explicit annotations, not decoration: luau-lsp 1.54.0 widens a
	-- required module's returned union type to plain `string` when it's
	-- read back through a module boundary without one (same reproduction as
	-- EconomyService.priceCommand's own comment).
	local coin: Coin, amount: number = Economy.toPrice(price)
	prompt.ActionText = Economy.format(coin, amount)
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = 10
	prompt.ClickablePrompt = clickable
	prompt.Enabled = true
	prompt.Parent = parent
	table.insert(trackedInstances, prompt)
	return prompt
end

local function connectPurchase(prompt: ProximityPrompt, itemType: ItemType, name: string, color: ShopColor, price: number)
	local conn = prompt.Triggered:Connect(function(player: Player)
		local data = DataService.Get(player)
		if data == nil then
			return
		end

		local code = ItemService.Encode(itemType, name, ItemService.ColorToCode(color.color))
		local decision = ShopService.Decide(data, itemType, code)
		if decision == "slotsFull" then
			fireFlavour(player, MAX_CAPACITY_LINES)
			return
		elseif decision == "owned" then
			fireFlavour(player, MATCH_LINES)
			return
		end

		local coinType: Coin, amount: number = Economy.toPrice(price)
		local paid = EconomyService.Pay(player, coinType, amount, string.format("Qarzin shop: %s %s", color.name, name))
		if not paid then
			return -- EconomyService.Pay already fired CoinMessage
		end

		if not ItemService.Wear(player, code) then
			log:Warn(string.format("%s paid for %s but Wear failed (no slot/character) - not refunded, matches a pre-existing edge case", player.Name, code))
		end
	end)
	table.insert(connections, conn)
end

local function recordListing(itemType: ItemType, name: string, color: ShopColor, price: number)
	table.insert(currentListings, { itemType = itemType, name = name, colorName = color.name, price = price })
end

-- ==================== stocking: hats and cloaks ====================

local function placeAccessory(holder: BasePart, name: string, itemType: "H" | "C")
	local asset = ReplicatedFirst.Assets:FindFirstChild(name)
	local template = asset and asset:FindFirstChildOfClass("MeshPart")
	if template == nil then
		log:Warn(string.format("shop: no MeshPart for %s %q", itemType, name))
		return
	end

	local color = Shop.RollColor(Shop.StandardColors)
	local clone = (template :: MeshPart):Clone()
	clone.Anchored = true

	local cf = holder.CFrame
	if itemType == "H" then
		local rotFix = Shop.HatRotationFix[name]
		if rotFix then
			cf = cf * rotFix
		end
	else
		cf = cf * CFrame.new(0, -1.5, 0) * CFrame.Angles(0, math.rad(180), 0)
		local offset = Shop.CloakOffsets[name]
		if offset then
			cf = cf * CFrame.new(offset.pos)
			if offset.extraRotY then
				cf = cf * CFrame.Angles(0, math.rad(offset.extraRotY), 0)
			end
		end
	end
	clone.CFrame = cf
	clone.Color = color.color
	clone.Parent = holder
	table.insert(trackedInstances, clone)

	local price = Shop.PriceFor(itemType, color)
	local prompt = createPrompt(holder, name, price, false)
	connectPurchase(prompt, itemType, name, color, price)
	recordListing(itemType, name, color, price)
end

local function stockHats(stand: Instance)
	local hatTable = stand:FindFirstChild(Shop.HatTableName)
	if hatTable == nil then
		return
	end
	local holders = childrenNamed(hatTable, Shop.HeadHolderName, "BasePart")
	if #holders == 0 then
		return
	end

	local names = shuffled(Shop.HatNames)
	local minCount, maxCount = Shop.StockRange(#holders)
	local amount = math.min(math.random(minCount, maxCount), #names, #holders)

	for i = 1, amount do
		placeAccessory(holders[i] :: BasePart, names[i], "H")
	end
end

local function stockCloaks(stand: Instance)
	local standTable = stand:FindFirstChild(Shop.StandTableName)
	if standTable == nil then
		return
	end
	local holders = childrenNamed(standTable, Shop.CloakHolderName, "BasePart")
	if #holders == 0 then
		return
	end

	-- Every holder gets a distinct cloak (docs dump #2: "every one of the 3
	-- holders"), not a partial random subset like hats.
	local names = shuffled(Shop.CloakNames)
	local amount = math.min(#holders, #names)
	for i = 1, amount do
		placeAccessory(holders[i] :: BasePart, names[i], "C")
	end
end

-- ==================== stocking: shirts and pants ====================

local function pickUnusedRack(racks: { Model }, used: { [Model]: boolean }): Model?
	local candidates: { Model } = {}
	for _, rack in racks do
		if not used[rack] then
			table.insert(candidates, rack)
		end
	end
	if #candidates == 0 then
		return nil
	end
	return candidates[math.random(1, #candidates)]
end

local function dressRack(rack: Model, shirtItem: ClothingItem, shirtColor: ShopColor, pantsItem: ClothingItem, pantsColor: ShopColor)
	for _, part in rack:GetDescendants() do
		if
			part:IsA("BasePart")
			and part.Name ~= "HumanoidRootPart"
			and part.Name ~= Shop.ShirtHLName
			and part.Name ~= Shop.PantsHLName
		then
			part.Transparency = 0
		end
		if part:IsA("BasePart") then
			part.CollisionGroup = "Default"
		end
	end
	table.insert(dressedRacks, rack)

	local shirt = rack:FindFirstChildOfClass("Shirt")
	if shirt then
		shirt.ShirtTemplate = shirtItem.id
		shirt.Color3 = shirtColor.color
	end
	local pants = rack:FindFirstChildOfClass("Pants")
	if pants then
		pants.PantsTemplate = pantsItem.id
		pants.Color3 = pantsColor.color
	end

	local shirtPrice = Shop.PriceFor("S", shirtColor)
	local pantsPrice = Shop.PriceFor("P", pantsColor)

	local shirtHL = rack:FindFirstChild(Shop.ShirtHLName, true)
	if shirtHL and shirtHL:IsA("BasePart") then
		shirtHL.CollisionGroup = "Default"
		local objectText = string.format("%s %s", shirtColor.name, shirtItem.name)
		local prompt = createPrompt(shirtHL, objectText, shirtPrice, true)
		connectPurchase(prompt, "S", shirtItem.name, shirtColor, shirtPrice)
		recordListing("S", shirtItem.name, shirtColor, shirtPrice)
	end
	local pantsHL = rack:FindFirstChild(Shop.PantsHLName, true)
	if pantsHL and pantsHL:IsA("BasePart") then
		pantsHL.CollisionGroup = "Default"
		local objectText = string.format("%s %s", pantsColor.name, Shop.PantsDisplayName)
		local prompt = createPrompt(pantsHL, objectText, pantsPrice, true)
		connectPurchase(prompt, "P", pantsItem.name, pantsColor, pantsPrice)
		recordListing("P", pantsItem.name, pantsColor, pantsPrice)
	end
end

local function stockOutfits(stand: Instance)
	local outfitTable = stand:FindFirstChild(Shop.OutfitTableName)
	if outfitTable == nil then
		return
	end
	local racks: { Model } = {}
	for _, child in childrenNamed(outfitTable, Shop.ClothingRackName, "Model") do
		table.insert(racks, child :: Model)
	end
	if #racks == 0 then
		return
	end

	local shirtPool = shuffled(Shop.ForSale(Shop.Shirts))
	local pantsPool = Shop.ForSale(Shop.Pants)
	if #shirtPool == 0 or #pantsPool == 0 then
		log:Warn("shop: no for-sale shirts or pants in Shared/Data/Shop.luau")
		return
	end

	local minCount, maxCount = Shop.StockRange(#racks)
	local amount = math.min(math.random(minCount, maxCount), #shirtPool, #racks)

	local used: { [Model]: boolean } = {}
	for i = 1, amount do
		local rack = pickUnusedRack(racks, used)
		if rack == nil then
			break
		end
		used[rack] = true

		local shirtItem = shirtPool[i]
		local pantsItem = pantsPool[math.random(1, #pantsPool)]
		local shirtColor = Shop.RollColor(Shop.VarietyColors)
		local pantsColor = Shop.RollColor(Shop.StandardColors)

		dressRack(rack, shirtItem, shirtColor, pantsItem, pantsColor)
	end
end

-- ==================== top-level stock/restock ====================

-- Typed as variadic (not `()`) so pcall(stockStand) below type-checks as
-- (boolean, ...any) instead of just (boolean) - same trick DevService's
-- AgeChangeHook and Main.server.luau's ServiceModule contract use.
local function stockStand(): ...any
	local stand = getStand()
	if stand == nil then
		log:Warn("Workspace.Qarzin.ClothesStand not found; shop not stocked")
		return
	end

	clearStock()
	stockHats(stand)
	stockOutfits(stand)
	stockCloaks(stand)
	log:Info(string.format("Qarzin clothes stand stocked (%d items)", #currentListings))
end

-- ==================== dev commands ====================

local function listingLine(listing: Listing): string
	local coin: Coin, amount: number = Economy.toPrice(listing.price)
	return string.format("%s %s (%s) - %s", listing.itemType, listing.name, listing.colorName, Economy.format(coin, amount))
end

local function registerDevCommands()
	DevService.Register("shop", "restock|list - manage the Qarzin clothes shop", function(_caller: Player, args: { string })
		local sub = args[1] and args[1]:lower()
		if sub == "restock" then
			stockStand()
			return string.format("Qarzin stand restocked: %d items", #currentListings)
		elseif sub == "list" then
			if #currentListings == 0 then
				return "Qarzin stand: nothing stocked"
			end
			local lines: { string } = {}
			for _, listing in currentListings do
				table.insert(lines, listingLine(listing))
			end
			return table.concat(lines, "\n")
		end
		return "usage: .shop restock|list"
	end)
end

-- ==================== service ====================

function ShopService:Init()
	local stand = getStand()
	if stand then
		local studioScript = stand:FindFirstChild(Shop.StudioScriptName)
		if studioScript and studioScript:IsA("Script") then
			studioScript.Disabled = true
			log:Info("disabled the Studio-only ClothingSpawn script (Bryan deletes it once this phase passes)")
		end
	else
		log:Warn("Workspace.Qarzin.ClothesStand not found at Init")
	end
	registerDevCommands()
end

function ShopService:Start()
	task.wait(Shop.StockDelaySeconds)
	local ok, err = pcall(stockStand)
	if not ok then
		log:Error("stocking the Qarzin stand failed: " .. tostring(err))
	end
end

return ShopService
