--!strict
-- The coin purse HUD (StarterGui.Currency, m2-studio-dump.md section 5) and
-- the coin flavour lines the old game posted as the character "saying"
-- them (old InputHandler.client.luau: TextChatService.TextChannels.
-- RBXGeneral:SendAsync(msg), which BUG-02 confirms still runs under
-- TextChatService in this place) -- kept as-is, no fallback needed.
--
-- Contract with the server (M5A-01, Shared/Remotes.luau):
--   Player attributes Copper/Silver/Gold (integers), kept current by
--   EconomyService.
--   CoinMessage(text: string) -- server -> client, a flavour line to post.
--
-- Currency is a StarterGui ScreenGui, NOT synced by Rojo -- found at
-- runtime in PlayerGui the same way HudController finds HUD. Same
-- ResetOnSpawn-true assumption as HUD (HudController's file header), so
-- it's rebound on every CharacterAdded, not just once.
--
-- No client-side money logic: the labels only ever mirror the Copper/
-- Silver/Gold attributes the server already computed.
--
-- Follow-up (Bryan, 2026-09-29): the CoinReward sound (CharacterService
-- clones it onto character.Torso, the same one the old save script and
-- LegacyBridge played) must play on every real Copper/Silver/Gold change,
-- up or down, so the player is alerted even without looking at the purse --
-- but never on the initial fill at join/respawn.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared:WaitForChild("Log"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local log = Log.new("CurrencyController")

local player = Players.LocalPlayer

local CurrencyController = {}

local COINS = { "Copper", "Silver", "Gold" }
local CURRENCY_GUI_TIMEOUT = 5
local COIN_SOUND_TIMEOUT = 5

local loggedMissingGui = false
local loggedMissingSound = false

local function warnMissingGuiOnce(message: string)
	if not loggedMissingGui then
		loggedMissingGui = true
		log:Warn(message)
	end
end

local function warnMissingSoundOnce(message: string)
	if not loggedMissingSound then
		loggedMissingSound = true
		log:Warn(message)
	end
end

local function findPurseLabels(): { [string]: TextLabel }?
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	local currencyGui = playerGui:FindFirstChild("Currency") or playerGui:WaitForChild("Currency", CURRENCY_GUI_TIMEOUT)
	if not currencyGui then
		warnMissingGuiOnce("PlayerGui.Currency missing; coin purse HUD disabled")
		return nil
	end

	local bank = currencyGui:FindFirstChild("Bank")
	local purse = bank and bank:FindFirstChild("CoinPurse")
	if not purse then
		warnMissingGuiOnce("Currency.Bank.CoinPurse missing; coin purse HUD disabled")
		return nil
	end

	local labels: { [string]: TextLabel } = {}
	for _, coin in COINS do
		local label = purse:FindFirstChild(coin)
		if label and label:IsA("TextLabel") then
			labels[coin] = label
		end
	end
	if not (labels.Copper and labels.Silver and labels.Gold) then
		warnMissingGuiOnce("Currency.Bank.CoinPurse.{Gold,Silver,Copper} missing; coin purse HUD disabled")
		return nil
	end

	return labels
end

-- CharacterService clones CoinReward onto the character's Torso (the same
-- sound the old save script and LegacyBridge played); bounded-wait since
-- it's attached server-side and may replicate a beat after CharacterAdded.
local function findCoinSound(): Sound?
	local character = player.Character
	if not character then
		return nil
	end
	local torso = character:FindFirstChild("Torso") or character:WaitForChild("Torso", COIN_SOUND_TIMEOUT)
	if not torso then
		warnMissingSoundOnce("character has no Torso; coin sound disabled")
		return nil
	end
	local sound = torso:FindFirstChild("CoinReward") or torso:WaitForChild("CoinReward", COIN_SOUND_TIMEOUT)
	if not sound or not sound:IsA("Sound") then
		warnMissingSoundOnce("Torso.CoinReward missing; coin sound disabled")
		return nil
	end
	return sound
end

-- Binds the purse labels and the coin alert sound to the Copper/Silver/Gold
-- attributes. The sound plays on every real change (up or down) but never
-- on the initial fill below (join or respawn) -- only GetAttributeChangedSignal
-- firings count as a "change".
local function bindCurrency(): { RBXScriptConnection }
	local labels = findPurseLabels()
	local coinSound = findCoinSound()

	local function update(coin: string, playSound: boolean)
		local amount = player:GetAttribute(coin)
		if typeof(amount) ~= "number" then
			return
		end
		local label = labels and labels[coin]
		if label then
			label.Text = tostring(amount)
		end
		if playSound and coinSound then
			coinSound:Play()
		end
	end

	local connections: { RBXScriptConnection } = {}
	for _, coin in COINS do
		table.insert(
			connections,
			player:GetAttributeChangedSignal(coin):Connect(function()
				update(coin, true)
			end)
		)
		update(coin, false)
	end

	return connections
end

local activeConnections: { RBXScriptConnection } = {}

local function disconnectAll()
	for _, connection in activeConnections do
		connection:Disconnect()
	end
	table.clear(activeConnections)
end

local function bindForCurrentGui()
	disconnectAll()
	for _, connection in bindCurrency() do
		table.insert(activeConnections, connection)
	end
end

-- ==================== coin messages ====================

local function postCoinMessage(text: string)
	local textChannels = TextChatService:FindFirstChild("TextChannels")
	local speech = textChannels and textChannels:FindFirstChild("RBXGeneral")
	if not speech or not speech:IsA("TextChannel") then
		log:Warn("TextChatService.TextChannels.RBXGeneral missing; coin message dropped: " .. text)
		return
	end
	speech:SendAsync(text)
end

function CurrencyController:Init() end

function CurrencyController:Start()
	player.CharacterAdded:Connect(bindForCurrentGui)
	if player.Character then
		bindForCurrentGui()
	end

	Remotes.Client.On("CoinMessage", function(text: any)
		if typeof(text) ~= "string" then
			log:Warn("CoinMessage: unexpected payload")
			return
		end
		postCoinMessage(text)
	end)

	log:Info("ready")
end

return CurrencyController
