--!strict
-- The character-creation ("Gender") screen. Clones ReplicatedFirst.GUI.Gender
-- (Studio-only art, kept exactly), destroys its Studio-only `Decisions`
-- Script (the old server script that could never actually see a player's
-- clicks), and reproduces its behaviour in a LocalScript instead: pick a
-- gender and a skin, Enter lights up once both are picked, Enter fires
-- CreateCharacter. The screen is destroyed once the server confirms the
-- pick by setting the Gender attribute to a non-zero value.
--
-- Contract with the server (M2-01/M2-03):
--   CreateCharacter(gender: 1|2, skin: 1|2|3) -- client -> server.
--   Player:GetAttribute("Gender") starts at 0 (or nil for a moment at
--   join) and becomes non-zero once the server accepts the pick.

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared:WaitForChild("Log"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local log = Log.new("CreationController")

local player = Players.LocalPlayer

-- Colours and behaviour straight from docs/reference/m2-studio-dump.md §1.
local MASCULINE_DEFAULT = Color3.fromRGB(84, 126, 189)
local MASCULINE_SELECTED = Color3.fromRGB(47, 72, 108)
local FEMININE_DEFAULT = Color3.fromRGB(189, 91, 21)
local FEMININE_SELECTED = Color3.fromRGB(117, 56, 13)

local ENTER_INACTIVE_TRANSPARENCY = 0.8
local ENTER_ACTIVE_TRANSPARENCY = 0

local GENDER_TEMPLATE = ReplicatedFirst:WaitForChild("GUI"):WaitForChild("Gender") :: ScreenGui

local CreationController = {}

local shown = false
local currentGui: ScreenGui? = nil

local function buildScreen()
	if shown then
		return
	end
	shown = true

	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

	local gui = GENDER_TEMPLATE:Clone()
	gui.ResetOnSpawn = false -- (REVIEW-M2-04 M1)
	-- FIX BUG-14: recursive, and destroyed before the clone is parented
	-- (below), same as MenuController's MenuMechanics fix.
	local decisions = gui:FindFirstChild("Decisions", true)
	if decisions then
		decisions:Destroy()
	end
	currentGui = gui

	local background = gui:WaitForChild("Background") :: Frame
	local genderFrame = background:WaitForChild("Gender") :: Frame
	local masculine = genderFrame:WaitForChild("Masculine") :: TextButton
	local feminine = genderFrame:WaitForChild("Feminine") :: TextButton
	local skinColor = background:WaitForChild("SkinColor") :: Frame
	local blackBox = skinColor:WaitForChild("BlackSkinBox") :: Frame
	local brownBox = skinColor:WaitForChild("BrownSkinBox") :: Frame
	local whiteBox = skinColor:WaitForChild("WhiteSkinBox") :: Frame
	local enter = background:WaitForChild("Enter") :: TextButton

	local genderButtons: { [number]: TextButton } = { [1] = masculine, [2] = feminine }
	local genderDefaultColor: { [number]: Color3 } = { [1] = MASCULINE_DEFAULT, [2] = FEMININE_DEFAULT }
	local genderSelectedColor: { [number]: Color3 } = { [1] = MASCULINE_SELECTED, [2] = FEMININE_SELECTED }
	local skinBoxes: { [number]: Frame } = { [1] = blackBox, [2] = brownBox, [3] = whiteBox }

	local selectedGender: number? = nil
	local selectedSkin: number? = nil

	local function updateEnter()
		local active = selectedGender ~= nil and selectedSkin ~= nil
		enter.BackgroundTransparency = if active then ENTER_ACTIVE_TRANSPARENCY else ENTER_INACTIVE_TRANSPARENCY
		enter.AutoButtonColor = active
	end

	local function refreshGenderColors()
		for genderId, button in genderButtons do
			button.BackgroundColor3 = if selectedGender == genderId
				then genderSelectedColor[genderId]
				else genderDefaultColor[genderId]
		end
	end

	local function refreshSkinMarks()
		for skinId, box in skinBoxes do
			local button = box:WaitForChild("Button") :: TextButton
			button.Text = if selectedSkin == skinId then "S" else ""
		end
	end

	for genderId, button in genderButtons do
		button.MouseEnter:Connect(function()
			if selectedGender ~= genderId then
				button.BackgroundColor3 = genderSelectedColor[genderId]
			end
		end)
		button.MouseLeave:Connect(function()
			if selectedGender ~= genderId then
				button.BackgroundColor3 = genderDefaultColor[genderId]
			end
		end)
		button.Activated:Connect(function()
			selectedGender = genderId
			refreshGenderColors()
			updateEnter()
		end)
	end

	for skinId, box in skinBoxes do
		local button = box:WaitForChild("Button") :: TextButton
		button.MouseEnter:Connect(function()
			if selectedSkin ~= skinId then
				button.Text = "S?"
			end
		end)
		button.MouseLeave:Connect(function()
			if selectedSkin ~= skinId then
				button.Text = ""
			end
		end)
		button.Activated:Connect(function()
			selectedSkin = skinId
			refreshSkinMarks()
			updateEnter()
		end)
	end

	updateEnter()

	enter.Activated:Connect(function()
		if selectedGender == nil or selectedSkin == nil then
			return
		end
		Remotes.Client.Fire("CreateCharacter", selectedGender, selectedSkin)
	end)

	gui.Parent = playerGui
end

local function destroyScreen()
	if currentGui then
		currentGui:Destroy()
		currentGui = nil
	end
	shown = false
end

local function onGenderChanged()
	local gender = player:GetAttribute("Gender")
	if gender == 0 then
		buildScreen()
	elseif typeof(gender) == "number" and gender ~= 0 then
		destroyScreen()
	end
end

function CreationController:Init() end

function CreationController:Start()
	-- Connect before the first check so a change landing between the two
	-- can never be missed.
	player:GetAttributeChangedSignal("Gender"):Connect(onGenderChanged)
	onGenderChanged()
	log:Info("ready")
end

return CreationController
