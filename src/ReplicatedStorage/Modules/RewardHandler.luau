local module = {}

local Modifiers = {
	["TimeCrunch"] = {
		chance = 20,
		rewardMultiplier = 1.2,
		reqs = nil
	},
	["CourierLoop"] = {
		chance = 10,
		rewardMultiplier = 1,
		reqs = nil
	},
	["HighlyValuable"] = {
		chance = 10,
		rewardMultiplier = 1.5,
		reqs = {
			SafeRoute = 1
		}
	},
	["HeavyCargo"] = {
		chance = 3,
		rewardMultiplier = 1.3,
		reqs = nil
	},
	["VIP"] = {
		chance = 1,
		rewardMultiplier = 2,
		reqs = {
			PlayerActive = 0,
			SafeRoute = 0
		}
	},
	["FragilePackage"] = {
		chance = 20,
		rewardMultiplier = 1.3,
		reqs = nil
	},
	["CleartheRoute"] = {
		chance = 3,
		rewardMultiplier = 1.5,
		reqs = {
			SafeRoute = 0
		}
	},
	["Nothing"] = {
		chance = 40
	}
}

module.playerlevel = function(maxmagoi, race) -- how strong they are
	local levelThresholds = {  -- magoi needed to reach each level
		{1, 10, 50}, -- fanalis
		{10, 100, 500}, --human
		{10, 100, 500}, -- immuchakk
		{100, 1000, 5000} -- magician
	}

	local threshold = levelThresholds[race]

	local level = 0
	for i = 1, #threshold do
		if maxmagoi >= threshold[i] then
			level += 1
		else
			break
		end
	end

	return level
end

module.population = function() -- total number of players
	local totalpop = #game.Players:GetPlayers()
	return totalpop
end

module.success = function(player)
	local totalsuccess = 0
	for _,v in player.SuccessRate:GetChildren() do
		if v.Name == "Delivery" then
			totalsuccess += 1
		end
	end

	return totalsuccess
end

module.citymodifier = function(modTable)
	local Add = 0
	for _,v in modTable do
		Add += Modifiers[v.Name].rewardMultiplier - 1
	end
	
	return Add
end

module.rewardcaculation = function(player) -- final caculation
	local statTable = player.Stats

	local base = 1
	local weaklingBonus = 10 / module.playerlevel(statTable.MaxMagoi.Value, statTable.Race.Value)
	local population = module.population() * 1.25
	local successrate = module.success(player) * 1.25
	
	-- TODO: Bonus would need to be set up post the oirignal caculation.

	return math.floor(base + weaklingBonus + population + successrate)
end

module.missionsuccess = function(player, gank, amount, modTable)
	if not gank then
		local amount = module.rewardcaculation(player)
		local mods = module.citymodifier(modTable) + 1
		player.OnCharacter.Currency.Copper.Value += amount * mods --money

		local victoryVal = Instance.new("IntValue") --victoryval
		victoryVal.Name = "Delivery"
		victoryVal.Parent = player.SuccessRate
	else -- ganked to get this
		player.OnCharacter.Currency.Copper.Value += amount
	end
end

module.missionfailure = function(player)
	
end

return module
