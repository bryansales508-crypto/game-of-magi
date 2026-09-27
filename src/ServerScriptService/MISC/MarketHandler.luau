DesertCities = {
	Qarzin = {
		State = "Neutral",
		Owner = nil,
		Wealth = 10000,

		Resources = {
			Fruit = {Supply = 5, Demand = 10, BasePrice = 1},
			Clothing = {Supply = 10, Demand = 10, BasePrice = 80},
			Weapons = {Supply = 5, Demand = 10, BasePrice = 180},
			Materials = {Supply = 3, Demand = 10, BasePrice = 15}
		}
	}
}

forcedChatsMsgs = {
	Money = {
		NeedMoney = {
			"I need more money...",
			"Oh wait, I'm broke!",
			"I don't have that much...",
			"No IOU's?"
		},
		Convert = {
			Copper = {
				"This place only takes Copper, huh...",
				"I need to convert my money...",
				"Forgot, I don't have Copper on me..."
			}
		},
		MaximumCapacity = {
			"I don't have enough room...",
			"I need to go store something..."
		},
		Match = {
			"Didn't I buy this?",
			"Don't I have this already...",
			"I legit have this on."
		}
	}
}

local eventFC = game.ReplicatedStorage.Remotes.MiscRemotes:WaitForChild("ForcedChat")
local itemHandler = require(game.ServerScriptService.Character.ItemHandler)

local module = {}

function module.GetPrice(city, resource, rC, itemType)
	local data = DesertCities[city].Resources[resource]

	local supply = data.Supply
	local demand = data.Demand
	local base = data.BasePrice

	local commonPrice = base * (demand / math.max(supply, 1)) -- throttle prevention
	local priceTag = nil
	
	if itemType == "H" then
		commonPrice = commonPrice * 1.2
	elseif itemType == "C" then
		commonPrice = commonPrice * 1.5
	end
	
	if rC.PriceMult then -- checking for price multiplier
		priceTag = math.ceil(commonPrice * rC.PriceMult) 
	else 
		priceTag = math.ceil(commonPrice)
	end
	
	local marketPrice -- visual price
	local coin -- copper, silver, or gold

	if priceTag >= 1000 then -- go to silver
		marketPrice = math.ceil(priceTag / 1000)
		coin = "Silver"
		if marketPrice >= 100 then -- go to gold
			marketPrice = math.ceil(marketPrice / 100 )
			coin = "Gold"
		end
	else -- stay copper
		marketPrice = priceTag 
		coin = "Copper"
	end

	return marketPrice, coin
end

function module.GetPlayerEcon(player, price, coinType, code)
	local oc = player:FindFirstChild("OnCharacter")
	local currencyStat = oc:FindFirstChild("Currency")
	local itemType = string.sub(code,1,1)
	

	-- total all coinage in Copper-equivalent
	local currentBank = 0
	for _, coin in currencyStat:GetChildren() do
		local mult = (coin.Name == "Gold" and 10000) or (coin.Name == "Silver" and 1000) or 1
		currentBank += coin.Value * mult
	end

	local enoughMoney = "no"

	if currentBank >= price then
		if currencyStat:FindFirstChild(coinType).Value >= price then
			-- returns: blocked(bool), reason("match" or nil)
			local function inventoryFull()
				if itemType == "H" or itemType == "C" then
					local hasSpace = false
					for _, slot in oc:FindFirstChild("Hats"):GetChildren() do
						if slot.Value == "" then
							hasSpace = true
						elseif slot.Value == code then
							return true, "match"
						end
					end
					return not hasSpace
				elseif itemType == "S" or itemType == "P" then
					local _, name = code:split("|")[1], code:split("|")[2]
					local worn = (itemType == "S") and player.Character:FindFirstChildOfClass("Shirt")
						or player.Character:FindFirstChildOfClass("Pants")
					if worn then
						local wornId = (itemType == "S") and worn.ShirtTemplate or worn.PantsTemplate
						local buyingId = itemHandler.clothingId(itemType, name)
						if wornId == buyingId then return true, "match" end
					end
					return false
				end
			end

			local blocked, reason = inventoryFull()
			if not blocked then
				currencyStat:FindFirstChild(coinType).Value -= price
				enoughMoney = "yes"
			elseif reason == "match" then
				enoughMoney = "Match"
			else
				enoughMoney = "MaximumCapacity"
			end
		else
			enoughMoney = "convert " .. coinType
		end
	end

	-- forced-chat feedback
	local msgPool
	if enoughMoney == "no" then
		msgPool = forcedChatsMsgs.Money.NeedMoney
	elseif enoughMoney == "convert Copper" then
		msgPool = forcedChatsMsgs.Money.Convert.Copper
	elseif enoughMoney == "MaximumCapacity" then
		msgPool = forcedChatsMsgs.Money.MaximumCapacity
	elseif enoughMoney == "Match" then
		msgPool = forcedChatsMsgs.Money.Match
	end

	if msgPool then
		eventFC:FireClient(player, msgPool[math.random(1, #msgPool)])
	end

	return enoughMoney
end

return module
