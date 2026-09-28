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

local loggedMissingGui = false

local function warnMissingGuiOnce(message: string)
	if not loggedMissingGui then
		loggedMissingGui = true
		log:Warn(message)
	end
end

local function bindPurse(): { RBXScriptConnection }
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	local currencyGui = playerGui:FindFirstChild("Currency") or playerGui:WaitForChild("Currency", CURRENCY_GUI_TIMEOUT)
	if not currencyGui then
		warnMissingGuiOnce("PlayerGui.Currency missing; coin purse HUD disabled")
		return {}
	end

	local bank = currencyGui:FindFirstChild("Bank")
	local purse = bank and bank:FindFirstChild("CoinPurse")
	if not purse then
		warnMissingGuiOnce("Currency.Bank.CoinPurse missing; coin purse HUD disabled")
		return {}
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
		return {}
	end

	local function update(coin: string)
		local label = labels[coin]
		local amount = player:GetAttribute(coin)
		if typeof(amount) ~= "number" then
			return
		end
		label.Text = tostring(amount)
	end

	local connections: { RBXScriptConnection } = {}
	for _, coin in COINS do
		table.insert(
			connections,
			player:GetAttributeChangedSignal(coin):Connect(function()
				update(coin)
			end)
		)
		update(coin)
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
	for _, connection in bindPurse() do
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
