--!strict
-- Face animation for one character's FalseHead: mouth flaps while the player chats,
-- random blinking, and a neutral/hurt face while the character has a Hit or Ragdoll
-- effect. CharacterService calls Start once per character.

local Log = require(game:GetService("ReplicatedStorage").Shared.Log)

local log = Log.new("FaceControl")

-- Blink/hurt faces reuse these three "human male 1/2" + "human female 1" face-base
-- ids from Assets.facebase; anything else keeps its normal face.
local BLINK_FACE_BASE: { [string]: string } = {
	["rbxassetid://13466958587"] = "rbxassetid://13467199372", -- human male 1
	["rbxassetid://13473200175"] = "rbxassetid://13473251210", -- human female 1
	["rbxassetid://13473204337"] = "rbxassetid://13482990162", -- human male 2
}

local HURT_MOUTH = "rbxassetid://95457103347003"
local HIT_MOUTH = "rbxassetid://76724770569093"
local YAP_MOUTHS = { "rbxassetid://13473292861", "rbxassetid://13473295251" }

local FaceControl = {}

-- Waits for `character.Effects` with no fixed timeout (EffectsService creates it once
-- AppearenceLoaded is true), but gives up cleanly if the character is destroyed first.
local function waitForEffects(character: Model): Instance?
	local existing = character:FindFirstChild("Effects")
	if existing then
		return existing
	end

	local found: Instance? = nil
	local connection: RBXScriptConnection
	connection = character.ChildAdded:Connect(function(child: Instance)
		if child.Name == "Effects" then
			found = child
		end
	end)

	while found == nil and character.Parent ~= nil do
		task.wait()
	end
	connection:Disconnect()
	return found
end

-- `falseHead` must already have FaceBase, MouthShape, EyeColor and EyeBrow
-- Decals parented under it (CharacterService builds those first).
function FaceControl.Start(player: Player, character: Model, falseHead: Instance)
	local mouthShape = falseHead:FindFirstChild("MouthShape")
	local eyeColor = falseHead:FindFirstChild("EyeColor")
	local faceBase = falseHead:FindFirstChild("FaceBase")
	if not (mouthShape and mouthShape:IsA("Decal") and eyeColor and eyeColor:IsA("Decal") and faceBase and faceBase:IsA("Decal")) then
		log:Warn(string.format("%s's FalseHead is missing a face Decal; skipping face control", player.Name))
		return
	end

	local mouthId = mouthShape.Texture
	local eyeColorId = eyeColor.Texture
	local faceBaseId = faceBase.Texture

	-- Clone the two template Values (siblings of this module) rather than building fresh ones.
	local wateryTemplate = script:FindFirstChild("WateryEyes")
	local talkCountTemplate = script:FindFirstChild("TalkCount")
	if not (wateryTemplate and talkCountTemplate) then
		log:Error("FaceControl WateryEyes/TalkCount templates missing")
		return
	end
	local watery = wateryTemplate:Clone() :: IntValue
	watery.Parent = falseHead
	local talkCount = talkCountTemplate:Clone() :: IntValue
	talkCount.Parent = falseHead

	-- Every connection this character's FaceControl makes is disconnected together once,
	-- so they don't pile up across respawns.
	local connections: { RBXScriptConnection } = {}
	local function track(connection: RBXScriptConnection)
		table.insert(connections, connection)
	end
	local cleanedUp = false
	local function cleanup()
		if cleanedUp then
			return
		end
		cleanedUp = true
		for _, connection in connections do
			connection:Disconnect()
		end
	end
	track(character.Destroying:Connect(cleanup))

	local talking = false
	local locked = false
	local locked2 = false
	local allowedToTalk = true
	local prevMouth: number? = nil

	local function yap()
		if locked or not allowedToTalk then
			return
		end
		locked = true
		task.spawn(function()
			while talking do
				local shapeTable = { mouthId, YAP_MOUTHS[1], YAP_MOUTHS[2] }
				local roll = math.random(1, 3)
				while roll == prevMouth do
					roll = math.random(1, 3)
					task.wait()
				end
				mouthShape.Texture = shapeTable[roll]
				prevMouth = roll
				task.wait(0.25)
				if not talking then
					mouthShape.Texture = mouthId
				end
			end
		end)
	end

	track(player.Chatted:Connect(function(message: string)
		if not allowedToTalk then
			return
		end
		if not talking then
			talking = true
			yap()
			talkCount.Value += math.min(#message, 20)
		elseif talkCount.Value < 20 then
			talkCount.Value = math.min(20, talkCount.Value + #message)
		end
	end))

	track(talkCount.Changed:Connect(function(value: number)
		if value > 0 and not locked2 then
			locked2 = true
			task.spawn(function()
				while talkCount.Value > 0 do
					talkCount.Value -= 1
					task.wait(0.5)
				end
				locked = false
				locked2 = false
				talking = false
				mouthShape.Texture = mouthId
			end)
		end
	end))

	local allowedToBlink = true
	local locked3 = false

	local function blink()
		watery.Value = math.random(4, 9)
		if not allowedToBlink then
			return
		end
		eyeColor.Texture = ""
		faceBase.Texture = BLINK_FACE_BASE[faceBaseId] or faceBaseId
		task.delay(0.3, function()
			eyeColor.Texture = eyeColorId
			faceBase.Texture = faceBaseId
		end)
	end

	track(watery.Changed:Connect(function(value: number)
		if value > 0 and not locked3 then
			locked3 = true
			task.spawn(function()
				while watery.Value > 0 do
					watery.Value -= 1
					task.wait(1)
				end
				locked3 = false
			end)
		elseif value == 0 then
			blink()
		end
	end))

	blink()

	local effects = waitForEffects(character)
	if effects == nil then
		log:Warn(string.format("%s's character was removed before Effects appeared; hurt/knocked faces disabled", player.Name))
		return
	end

	local function setNeutralFace(mouthId2: string)
		eyeColor.Texture = ""
		faceBase.Texture = BLINK_FACE_BASE[faceBaseId] or faceBaseId
		mouthShape.Texture = mouthId2
	end

	local function restoreFace()
		eyeColor.Texture = eyeColorId
		faceBase.Texture = faceBaseId
		mouthShape.Texture = mouthId
	end

	track(effects.ChildAdded:Connect(function(effect: Instance)
		if effect.Name == "Ragdoll" then
			allowedToTalk = false
			allowedToBlink = false
			setNeutralFace(HURT_MOUTH)
		elseif effect.Name == "Hit" and not effects:FindFirstChild("Ragdoll") then
			allowedToTalk = false
			allowedToBlink = false
			setNeutralFace(HIT_MOUTH)
		end
	end))

	track(effects.ChildRemoved:Connect(function(effect: Instance)
		if effect.Name == "Ragdoll" or (effect.Name == "Hit" and not effects:FindFirstChild("Ragdoll")) then
			allowedToTalk = true
			allowedToBlink = true
			restoreFace()
		end
	end))
end

return FaceControl
