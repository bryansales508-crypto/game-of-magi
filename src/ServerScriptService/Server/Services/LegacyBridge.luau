--!strict
-- TEMPORARY. Deleted in the last milestone that stops using player.Stats /
-- player.OnCharacter. Until then, old scripts (M2-M6) still read and write
-- those Value folders directly, so this module mirrors the real save
-- (SaveSchema.Data, owned by DataService) into them and back.
--
-- Not a service: no Init/Start. DataService requires it directly.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local SaveSchema = require(ReplicatedStorage.Shared.SaveSchema)

local log = Log.new("LegacyBridge")

type Data = SaveSchema.Data

-- One instance per mirrored Value, plus the connections that keep the
-- Value <-> data direction in sync and need disconnecting on Destroy.
type Rig = {
	stats: Folder,
	onCharacter: Folder,
	race: IntValue,
	hairColor: Color3Value,
	firstName: StringValue,
	kingdom: IntValue,
	maxMagoi: IntValue,
	eyeColor: IntValue,
	faceBase: IntValue,
	gender: IntValue,
	age: IntValue,
	height: NumberValue,
	growthProfile: StringValue,
	mouthShape: IntValue,
	skinTone: IntValue,
	timePassed: IntValue,
	progToAge: IntValue,
	hunger: NumberValue,
	shirt: StringValue,
	pants: StringValue,
	copper: IntValue,
	silver: IntValue,
	gold: IntValue,
	hat1: StringValue,
	hat2: StringValue,
	hat3: StringValue,
	row1: StringValue,
	row2: StringValue,
	position: Vector3Value,
	loadedOC: BoolValue,
	loaded: BoolValue,
	connections: { RBXScriptConnection },
}

local rigs: { [Player]: Rig } = {}
-- True while LegacyBridge itself is writing Values from data. Under
-- Roblox's default Deferred signal behavior, a Value's .Changed handler
-- doesn't run until after this flag is already back to false (mirroring
-- only helps the immediate-signal-behavior case), so the real defense
-- against writing an echo straight back into data is each watcher below
-- comparing the new value against what's already there before writing
-- (REVIEW-M1-03 L7). Kept anyway: it's still correct when it does apply,
-- and it's what marks a write as "ours" if that's ever needed later.
local mirroring: { [Player]: boolean } = {}

local function joinInventory(items: { string }): string
	return table.concat(items, ";")
end

local function splitInventory(joined: string): { string }
	if joined == "" then
		return {}
	end
	return string.split(joined, ";")
end

local COIN_GUI_TIMEOUT = 5

-- Old OnCharacterStore2 kept the coin purse HUD text in sync itself (it was
-- the only thing that ever wrote it), on both the initial load and every
-- later change, plus a CoinReward sound on change (REVIEW-M1-03 M5).
-- Bounded WaitForChild (old code's was unbounded) so a missing/renamed GUI
-- can't hang the bridge the way the old MainScreen wait used to (H3).
local function coinPurseLabel(player: Player, coin: "Copper" | "Silver" | "Gold"): TextLabel?
	local playerGui = player:FindFirstChild("PlayerGui")
	if playerGui == nil then
		return nil
	end
	local currency = playerGui:WaitForChild("Currency", COIN_GUI_TIMEOUT)
	if currency == nil then
		return nil
	end
	local bank = currency:FindFirstChild("Bank")
	local purse = bank and bank:FindFirstChild("CoinPurse")
	local label = purse and purse:FindFirstChild(coin)
	if label and label:IsA("TextLabel") then
		return label
	end
	return nil
end

local function updateCoinPurseText(player: Player, coin: "Copper" | "Silver" | "Gold", amount: number)
	local label = coinPurseLabel(player, coin)
	if label then
		label.Text = tostring(amount)
	end
end

local function playCoinRewardSound(player: Player)
	local character = player.Character
	local torso = character and character:FindFirstChild("Torso")
	local sound = torso and torso:FindFirstChild("CoinReward")
	if sound and sound:IsA("Sound") then
		sound:Play()
	end
end

-- Pushes `data` onto every mirrored Value (data -> Value direction). Used
-- for the initial Build and for Refresh after a Wipe.
local function pushToInstances(player: Player, rig: Rig, data: Data)
	mirroring[player] = true

	rig.race.Value = data.Character.Race
	rig.hairColor.Value = Color3.new(data.Character.HairColor.R, data.Character.HairColor.G, data.Character.HairColor.B)
	rig.firstName.Value = data.Character.FirstName
	rig.kingdom.Value = data.Character.Kingdom
	-- One-way: nothing currently active writes Stats.MaxMagoi back (the
	-- only writer, LevelHandler, is parked). Old health code only reads it.
	rig.maxMagoi.Value = data.Progress.Magoi
	rig.eyeColor.Value = data.Character.EyeColor
	rig.faceBase.Value = data.Character.FaceBase
	rig.gender.Value = data.Character.Gender
	rig.age.Value = data.Age.Years
	rig.height.Value = data.Character.Height
	rig.growthProfile.Value = data.Character.GrowthProfile
	rig.mouthShape.Value = data.Character.MouthShape
	rig.skinTone.Value = data.Character.SkinTone
	rig.timePassed.Value = data.Age.TimePassed
	rig.progToAge.Value = data.Age.ProgToAge
	-- Hunger is parked (TRIAGE K1): fixed at the old "not eating yet" value.
	rig.hunger.Value = 5

	rig.shirt.Value = data.Gear.Shirt
	rig.pants.Value = data.Gear.Pants
	rig.copper.Value = data.Economy.Copper
	rig.silver.Value = data.Economy.Silver
	rig.gold.Value = data.Economy.Gold
	updateCoinPurseText(player, "Copper", data.Economy.Copper)
	updateCoinPurseText(player, "Silver", data.Economy.Silver)
	updateCoinPurseText(player, "Gold", data.Economy.Gold)
	rig.hat1.Value = data.Gear.Hats[1] or ""
	rig.hat2.Value = data.Gear.Hats[2] or ""
	rig.hat3.Value = data.Gear.Hats[3] or ""
	rig.row1.Value = joinInventory(data.Gear.Inventory)
	-- Row2 is always empty: the old menu never wrote it, and the new schema
	-- keeps one Inventory list, not two rows.
	rig.row2.Value = ""

	mirroring[player] = false
end

-- Connects the Value -> data direction (old scripts writing to a mirrored
-- Value updates the real save). Call once, after the initial push.
local function connectAll(player: Player, data: Data, rig: Rig)
	local connections = rig.connections

	-- `value` is typed `any` here on purpose: every ValueBase class (IntValue,
	-- StringValue, ...) has a differently-parametrized Changed signal, and
	-- this helper is only ever called below with a concrete field of `rig`.
	local function watch(value: any, apply: (any) -> ())
		local connection: RBXScriptConnection = value.Changed:Connect(function(newValue: any)
			if mirroring[player] then
				return
			end
			apply(newValue)
		end)
		table.insert(connections, connection)
	end

	watch(rig.race, function(v: number)
		if data.Character.Race ~= v then
			data.Character.Race = v
		end
	end)
	watch(rig.hairColor, function(v: Color3)
		local hairColor = data.Character.HairColor
		if hairColor.R ~= v.R or hairColor.G ~= v.G or hairColor.B ~= v.B then
			data.Character.HairColor = { R = v.R, G = v.G, B = v.B }
		end
	end)
	watch(rig.firstName, function(v: string)
		if data.Character.FirstName ~= v then
			data.Character.FirstName = v
		end
	end)
	watch(rig.kingdom, function(v: number)
		if data.Character.Kingdom ~= v then
			data.Character.Kingdom = v
		end
	end)
	watch(rig.eyeColor, function(v: number)
		if data.Character.EyeColor ~= v then
			data.Character.EyeColor = v
		end
	end)
	watch(rig.faceBase, function(v: number)
		if data.Character.FaceBase ~= v then
			data.Character.FaceBase = v
		end
	end)
	watch(rig.gender, function(v: number)
		if data.Character.Gender ~= v then
			data.Character.Gender = v
		end
	end)
	watch(rig.age, function(v: number)
		if data.Age.Years ~= v then
			data.Age.Years = v
		end
	end)
	watch(rig.height, function(v: number)
		if data.Character.Height ~= v then
			data.Character.Height = v
		end
	end)
	watch(rig.growthProfile, function(v: string)
		if data.Character.GrowthProfile ~= v then
			data.Character.GrowthProfile = v
		end
	end)
	watch(rig.mouthShape, function(v: number)
		if data.Character.MouthShape ~= v then
			data.Character.MouthShape = v
		end
	end)
	watch(rig.skinTone, function(v: number)
		if data.Character.SkinTone ~= v then
			data.Character.SkinTone = v
		end
	end)
	watch(rig.timePassed, function(v: number)
		if data.Age.TimePassed ~= v then
			data.Age.TimePassed = v
		end
	end)
	watch(rig.progToAge, function(v: number)
		if data.Age.ProgToAge ~= v then
			data.Age.ProgToAge = v
		end
	end)

	watch(rig.shirt, function(v: string)
		if data.Gear.Shirt ~= v then
			data.Gear.Shirt = v
		end
	end)
	watch(rig.pants, function(v: string)
		if data.Gear.Pants ~= v then
			data.Gear.Pants = v
		end
	end)
	-- Currency also keeps the old coin purse HUD text and CoinReward sound
	-- in sync (REVIEW-M1-03 M5): old OnCharacterStore2 did both on every
	-- change, and nothing else does it now that script is gone.
	watch(rig.copper, function(v: number)
		if data.Economy.Copper ~= v then
			data.Economy.Copper = v
			updateCoinPurseText(player, "Copper", v)
			playCoinRewardSound(player)
		end
	end)
	watch(rig.silver, function(v: number)
		if data.Economy.Silver ~= v then
			data.Economy.Silver = v
			updateCoinPurseText(player, "Silver", v)
			playCoinRewardSound(player)
		end
	end)
	watch(rig.gold, function(v: number)
		if data.Economy.Gold ~= v then
			data.Economy.Gold = v
			updateCoinPurseText(player, "Gold", v)
			playCoinRewardSound(player)
		end
	end)
	watch(rig.hat1, function(v: string)
		if data.Gear.Hats[1] ~= v then
			data.Gear.Hats[1] = v
		end
	end)
	watch(rig.hat2, function(v: string)
		if data.Gear.Hats[2] ~= v then
			data.Gear.Hats[2] = v
		end
	end)
	watch(rig.hat3, function(v: string)
		if data.Gear.Hats[3] ~= v then
			data.Gear.Hats[3] = v
		end
	end)
	watch(rig.row1, function(v: string)
		if joinInventory(data.Gear.Inventory) ~= v then
			data.Gear.Inventory = splitInventory(v)
		end
	end)
	-- MaxMagoi, Hunger, Row2 and Position are one-way (see pushToInstances)
	-- or inert: nothing legitimate writes them today, so there's nothing to
	-- watch back.
end

local LegacyBridge = {}

function LegacyBridge.Build(player: Player, data: Data)
	if rigs[player] then
		log:Warn(string.format("Build called twice for %s; ignoring", player.Name))
		return
	end

	local stats = Instance.new("Folder")
	stats.Name = "Stats"

	local onCharacter = Instance.new("Folder")
	onCharacter.Name = "OnCharacter"

	local clothes = Instance.new("Folder")
	clothes.Name = "Clothes"
	clothes.Parent = onCharacter

	local currency = Instance.new("Folder")
	currency.Name = "Currency"
	currency.Parent = onCharacter

	local hats = Instance.new("Folder")
	hats.Name = "Hats"
	hats.Parent = onCharacter

	local inventory = Instance.new("Folder")
	inventory.Name = "Inventory"
	inventory.Parent = onCharacter

	local race = Instance.new("IntValue")
	race.Name = "Race"
	race.Parent = stats

	local hairColor = Instance.new("Color3Value")
	hairColor.Name = "HairColor"
	hairColor.Parent = stats

	local firstName = Instance.new("StringValue")
	firstName.Name = "FirstName"
	firstName.Parent = stats

	local kingdom = Instance.new("IntValue")
	kingdom.Name = "Kingdom"
	kingdom.Parent = stats

	local maxMagoi = Instance.new("IntValue")
	maxMagoi.Name = "MaxMagoi"
	maxMagoi.Parent = stats

	local eyeColor = Instance.new("IntValue")
	eyeColor.Name = "EyeColor"
	eyeColor.Parent = stats

	local faceBase = Instance.new("IntValue")
	faceBase.Name = "FaceBase"
	faceBase.Parent = stats

	local gender = Instance.new("IntValue")
	gender.Name = "Gender"
	gender.Parent = stats

	local age = Instance.new("IntValue")
	age.Name = "Age"
	age.Parent = stats

	local height = Instance.new("NumberValue")
	height.Name = "Height"
	height.Parent = stats

	local growthProfile = Instance.new("StringValue")
	growthProfile.Name = "GrowthProfile"
	growthProfile.Parent = stats

	local mouthShape = Instance.new("IntValue")
	mouthShape.Name = "MouthShape"
	mouthShape.Parent = stats

	local skinTone = Instance.new("IntValue")
	skinTone.Name = "SkinTone"
	skinTone.Parent = stats

	local timePassed = Instance.new("IntValue")
	timePassed.Name = "TimePassed"
	timePassed.Parent = stats

	local progToAge = Instance.new("IntValue")
	progToAge.Name = "ProgToAge"
	progToAge.Parent = stats

	local hunger = Instance.new("NumberValue")
	hunger.Name = "Hunger"
	hunger.Parent = stats

	local shirt = Instance.new("StringValue")
	shirt.Name = "Clothing_Shirt"
	shirt.Parent = clothes

	local pants = Instance.new("StringValue")
	pants.Name = "Clothing_Pants"
	pants.Parent = clothes

	local copper = Instance.new("IntValue")
	copper.Name = "Copper"
	copper.Parent = currency

	local silver = Instance.new("IntValue")
	silver.Name = "Silver"
	silver.Parent = currency

	local gold = Instance.new("IntValue")
	gold.Name = "Gold"
	gold.Parent = currency

	local hat1 = Instance.new("StringValue")
	hat1.Name = "HatSpot1"
	hat1.Parent = hats

	local hat2 = Instance.new("StringValue")
	hat2.Name = "HatSpot2"
	hat2.Parent = hats

	local hat3 = Instance.new("StringValue")
	hat3.Name = "HatSpot3"
	hat3.Parent = hats

	local row1 = Instance.new("StringValue")
	row1.Name = "Row1"
	row1.Parent = inventory

	local row2 = Instance.new("StringValue")
	row2.Name = "Row2"
	row2.Parent = inventory

	-- The old OnCharacterStore2 always created this (unconditionally, before
	-- its per-field loop), but its load/save/Changed handling was entirely
	-- commented out, so it just sat at the engine default (0,0,0) and was
	-- never read back into the save. Kept here, inert, for parity with any
	-- old script that still expects to find it (REVIEW-M1-03 M4).
	local position = Instance.new("Vector3Value")
	position.Name = "Position"
	position.Parent = onCharacter

	local loadedOC = Instance.new("BoolValue")
	loadedOC.Name = "LoadedOC"
	loadedOC.Value = false

	local loaded = Instance.new("BoolValue")
	loaded.Name = "Loaded"
	loaded.Value = false

	local rig: Rig = {
		stats = stats,
		onCharacter = onCharacter,
		race = race,
		hairColor = hairColor,
		firstName = firstName,
		kingdom = kingdom,
		maxMagoi = maxMagoi,
		eyeColor = eyeColor,
		faceBase = faceBase,
		gender = gender,
		age = age,
		height = height,
		growthProfile = growthProfile,
		mouthShape = mouthShape,
		skinTone = skinTone,
		timePassed = timePassed,
		progToAge = progToAge,
		hunger = hunger,
		shirt = shirt,
		pants = pants,
		copper = copper,
		silver = silver,
		gold = gold,
		hat1 = hat1,
		hat2 = hat2,
		hat3 = hat3,
		row1 = row1,
		row2 = row2,
		position = position,
		loadedOC = loadedOC,
		loaded = loaded,
		connections = {},
	}

	rigs[player] = rig
	mirroring[player] = false

	pushToInstances(player, rig, data)
	connectAll(player, data, rig)

	stats.Parent = player
	onCharacter.Parent = player
	loadedOC.Parent = player
	loadedOC.Value = true
	loaded.Parent = player
	loaded.Value = true
end

function LegacyBridge.Refresh(player: Player, data: Data)
	local rig = rigs[player]
	if rig == nil then
		log:Warn(string.format("Refresh called for %s but no bridge is built", player.Name))
		return
	end
	pushToInstances(player, rig, data)
end

function LegacyBridge.Destroy(player: Player)
	local rig = rigs[player]
	if rig == nil then
		return
	end
	for _, connection in rig.connections do
		connection:Disconnect()
	end
	rigs[player] = nil
	mirroring[player] = nil
end

return LegacyBridge
