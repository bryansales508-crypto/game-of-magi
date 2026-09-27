-- Services
local physerv = game:GetService("PhysicsService")
local heighthandler = require(game.ServerScriptService.Character.HeightHandler)
local agehandler = require(game.ServerScriptService.Character.AgeHandler)
local assets = require(game.ReplicatedFirst.Assets)
local ItemHandler = require(game.ServerScriptService.Character.ItemHandler)

local loadEvent = game.ReplicatedStorage.Remotes.MiscRemotes.MainScreen
local assets = require(game.ReplicatedFirst.Assets)

-- Functions

local function currentRatio(player)
	local stats = player.Stats
	local profile = agehandler.unpack(stats.GrowthProfile.Value)
	local fat = profile and agehandler.fatAt(profile, stats.Age.Value) or 0
	return heighthandler.heightToRatio(stats.Height.Value, fat)
end

-- stat references
--[[{
	["Age"] = Age,
	["Depravity"] = Depravity,
	["DjinnCapturer"] = DjinnCapturer,
	["DjinnEquip"] = DjinnEquip,
	["EyeColor"] = EyeColor,
	["FaceBase"] = FaceBase,
	["Family"] = Family,
	["FirstName"] = FirstName,
	["Gender"] = Gender,
	["HairColor"] = HairColor,
	["Height"] = Height,
	["Kingdom"] = Kingdom,
	["LovedByRukh"] = LovedByRukh,
	["MagicType"] = MagicType,
	["MagicType2"] = MagicType2,
	["Mark"] = Mark,
	["MaxMagoi"] = MaxMagoi,
	["MouthShape"] = MouthShape,
	["Race"] = Race,
	["Strength"] = Strength,
	["Bounty"] = Bounty,
    ["Clothes"] = Clothes,
    ["Currency"] = Currency,
    ["JailTime"] = JailTime,
    ["Lives"] = Lives,
    ["MagicItemInventory"] = MagicItemInventory,
    ["NPContinuation"] = NPContinuation,
    ["Position"] = Position,
    ["SkillSet1"] = SkillSet1,
    ["Spells"] = Spells
}]]


game.Players.PlayerAdded:Connect(function(player) -- TODO: The values have to freeze for the while loop to load.
	local heart = nil
	local heart2 = nil

	player.CharacterAdded:Connect(function(chara)
		-- player variables

		-- Appearence Value creation and setup
		local AppearenceValue = Instance.new("BoolValue")
		AppearenceValue.Value = false
		AppearenceValue.Name = "AppearenceLoaded"
		AppearenceValue.Parent = chara

		-- Wait for Values
		while player:WaitForChild("Loaded").Value == false do task.wait() end
		
		local loading = true -- loading through main screen
		local loadCon

		loadCon = loadEvent.OnServerEvent:Connect(function(LoadPly)
			if LoadPly == player then
					loading = false
					loadCon:Disconnect()
			end
		end)
		repeat task.wait() until loading == false

		-- chara variables
		local charaHum = chara:WaitForChild("Humanoid")
		chara.Parent = workspace.Characters
		
		-- setting up stats
		local stFold = player:WaitForChild("Stats")
		local oncharaFold = player:WaitForChild("OnCharacter")

		-- container tables
		local stat = {}
		local onC = {}

		-- insert variables
		for _,v in stFold:GetChildren() do
			local c = stFold:WaitForChild(v.Name)
			stat[v.Name] = c
		end

		for _,v in oncharaFold:GetChildren() do
			local c = oncharaFold:WaitForChild(v.Name)
			onC[v.Name] = c
		end

		-- pausing for stat load or new player
		while stat["Race"].Value == 0 do task.wait() end

		-- assigning gender if they don't have one
		if stat["Gender"].Value == 0 then
			local gui = game.ReplicatedFirst.GUI.Gender:Clone()
			gui.Parent = player.PlayerGui
		end

		-- waiting for gender
		while stat["Gender"].Value == 0 do
			if player.Parent ~= nil then -- wrapping just in case they leave
				if not player:FindFirstChild("PlayerGui"):FindFirstChild("Gender") and stat["Gender"].Value == 0 then
					local gui = game.ReplicatedFirst.GUI.Gender:Clone()
					gui.Parent = player.PlayerGui
				end
			end
			task.wait()
		end

		-- appearence work

		for _,v in chara:GetChildren() do -- ridding clothes
			-- hats
			if v:IsA("Accessory") then
				if v.AccessoryType == Enum.AccessoryType.Hair then
					for _,w in v:GetDescendants() do
						if w.Name == "Handle" then
							if w:FindFirstChild("SpecialMesh") then
								w.SpecialMesh.TextureId = ""
							end

							if w:FindFirstChild("Mesh") then
								w.Mesh.TextureId = ""
							end
						end
					end
				else
					v:Destroy()
				end
				-- clothes
			elseif v:IsA("Shirt") or v:IsA("Pants") then
				v:Destroy()
			end
		end

		local skin -- setting up skin
		
		if chara:FindFirstChild("BodyColors") then chara.BodyColors:Destroy() end -- destroying old skin tone
		if stat["SkinTone"].Value == 1 then -- assigning skin tone
			skin = script.Black:Clone()
		elseif stat["SkinTone"].Value == 2 then
			skin = script.Brown:Clone()
		else
			skin = script.White:Clone()
		end

		if stat["Kingdom"].Value == 1 then -- changing skin for kingdoms
			if skin.Name == "White" then
				skin = script.LightTan:Clone()
			end
		elseif stat["Kingdom"].Value == 2 then
			if skin.Name == "Black" then
				skin = script.Tan:Clone()
			elseif skin.Name == "Brown" then
				skin = script.LightTan:Clone()
			end
		end
		skin.Parent = chara -- depositing the skin tone

		local falsehead = script.FalseHead:Clone() -- setting up falsehead
		falsehead.Transparency = 1
		falsehead.CFrame = chara.Head.CFrame + (chara.Head.CFrame.LookVector/20)

		local fhweld = Instance.new("WeldConstraint")
		fhweld.Part0 = falsehead
		fhweld.Part1 = chara.Head
		fhweld.Parent = falsehead

		falsehead.Parent = chara

		local hitbox = game.ReplicatedFirst.MISC.HitBox:Clone() -- setting up hitbox
		hitbox.CFrame = chara.HumanoidRootPart.CFrame:ToWorldSpace(CFrame.new(0,0,-1))
		hitbox.Color = Color3.new(0.133333, 0.458824, 0.976471)


		local hitboxweld = Instance.new("WeldConstraint")
		hitboxweld.Part0 = chara.HumanoidRootPart
		hitboxweld.Part1 = hitbox
		hitboxweld.Parent = hitbox

		hitbox.Parent = chara

		if stat["Height"].Value == 10 then -- first time height, needs to be set.
			local profileStr, height = agehandler.start(stat["Age"].Value, stat["Race"].Value, stat["Gender"].Value)
			stat["GrowthProfile"].Value = profileStr -- must be set first
			stat["Height"].Value = height
		end

		for _,v in chara:GetChildren() do -- ridding meshes and putting on a standard mesh 
			if v:IsA("CharacterMesh") then v:Destroy() end
		end

		chara.Head:FindFirstChild("Mesh"):Destroy()
		local norm = script.NormMeshie:Clone()
		norm.Parent = chara.Head

		chara.Head:FindFirstChild("face"):Destroy() -- ridding old face

		local base = assets.facebase(stat) -- setting up new face
		base.Parent = chara.FalseHead

		local mouth = assets.mouthshape(stat)
		mouth.Parent = chara.FalseHead

		local eyecolor = assets.eyecolor(stat)
		eyecolor.Parent = chara.FalseHead

		local eyebrow = assets.eyebrow(stat)
		eyebrow.Parent = chara.FalseHead

		local facecontrol = script.FaceControl:Clone() -- giving face control
		facecontrol.Parent = chara.FalseHead

		for _,v in chara:GetDescendants() do -- coloring hair
			if v.Name:find("Handle") and v:IsA("BasePart") then
				v.Color = stat["HairColor"].Value
			end
		end

		--Collision Groups
		local collisionGroup1 = player.Name.."CollisionLimbs"
		pcall(function() physerv:RegisterCollisionGroup(collisionGroup1)
		end)

		for _,v in chara:GetChildren() do -- making limbs collidable.
			if v:IsA("BasePart") then
				v.CollisionGroup = collisionGroup1
			end
		end
		pcall(function() physerv:CollisionGroupSetCollidable(collisionGroup1, "ClothingRackGroup", false) -- don't want to collide into clothes
		end)
		-- SoundsTable
		local SoundsTable = {}
		for _,v in game.ReplicatedFirst.SFX:GetDescendants() do
			SoundsTable[v.Name] = v
		end

		-- TODO: You don't have to list out once this is all completed, just doing it for brevity sake.
		SoundsTable["CoinReward"]:Clone().Parent = chara.Torso
		SoundsTable["BlockBroken"]:Clone().Parent = chara.Torso
		SoundsTable["Parry"]:Clone().Parent = chara.Torso
		SoundsTable["QuickDash"]:Clone().Parent = chara.Torso
		for i=1,4,1 do
			if i ~= 4 then
				SoundsTable["LightHitSound"..tostring(i)]:Clone().Parent = chara.Torso
				SoundsTable["MissSound"..tostring(i)]:Clone().Parent = chara.Torso

				if i == 1 or i == 2 then
					SoundsTable["BlockSound"..tostring(i)]:Clone().Parent = chara.Torso
				end
			else
				SoundsTable["LightHitSoundFin"]:Clone().Parent = chara.Torso
			end
		end

		-- Attachment Work
		local centerAtt = Instance.new("Attachment") -- middle of the torso
		centerAtt.Name = "CenterHook"
		centerAtt.Parent = chara.Torso

		local headAtt = Instance.new("Attachment") -- middle of the head
		headAtt.Name = "HeadHook"
		headAtt.Parent = chara.Head

		-- ParticleTable
		local ParticleTable = {}
		for _,v in game.ReplicatedFirst.VFX:GetDescendants() do
			ParticleTable[v.Name] = v
		end

		-- TODO: You don't have to list out once this is all completed, just doing it for brevity sake.
		ParticleTable["HitParticle"]:Clone().Parent = chara.Torso
		ParticleTable["Cancel"]:Clone().Parent = chara
		ParticleTable["BlockParticle"]:Clone().Parent = chara.Torso
		ParticleTable["BlockBreakParticle"]:Clone().Parent = chara.Torso
		ParticleTable["Confusion"]:Clone().Parent = chara.Head.HairAttachment
		ParticleTable["Sparks1"]:Clone().Parent = centerAtt
		ParticleTable["Sparks2"]:Clone().Parent = centerAtt

		-- Steps
		local stepSounds = game.ReplicatedFirst.SFX.Steps:Clone()
		for _,v in stepSounds:GetChildren() do
			v.Parent = chara.Torso
		end

		-- Music
		local Sounds = Instance.new("Folder")
		Sounds.Parent = chara:WaitForChild("Torso")
		Sounds.Name = "SoundsFolder"

		for _,v in game.ReplicatedFirst.SFX.OSTs:GetChildren() do
			local c = v:Clone()
			c.Parent = Sounds
		end

		-- Finished
		AppearenceValue.Value = true
		chara.Parent = workspace.Characters

		local clothes = player.OnCharacter:WaitForChild("Clothes") -- "equipping" outfit
		if clothes.Clothing_Shirt.Value == "" then -- starter outfit

			local rP = math.random(1,2)
			local coloring
			if math.random(1,2) == 1 then coloring = Color3.fromRGB(35, 35, 35) else coloring = Color3.fromRGB(144, 90, 42) end
			local clothItemP
			if math.random(1,2) == 1 then clothItemP = "Shoes and Rags" else clothItemP = "Barefooted and Rags" end


			local shirtCode = ItemHandler.encode("S", "Short Sleeve Rags", ItemHandler.colorToCode(coloring))
			local pantsCode = ItemHandler.encode("P", clothItemP, ItemHandler.colorToCode(coloring))
			clothes.Clothing_Shirt.Value = shirtCode
			clothes.Clothing_Pants.Value = pantsCode
		end

		local shirtCode = clothes.Clothing_Shirt.Value
		if shirtCode ~= "" then
			ItemHandler.equip(shirtCode, chara)
		end

		local pantsCode = clothes.Clothing_Pants.Value
		if pantsCode ~= "" then
			ItemHandler.equip(pantsCode, chara)
		end

		-- misc stuff
		local successrate = Instance.new("Folder") -- used by mission handler / reward handler 
		successrate.Name = "SuccessRate"
		successrate.Parent = player

		local M6D = Instance.new("Motor6D", chara.Torso) -- or the part that you have decieded
		M6D.Name = "ToolGrip"

		chara.ChildAdded:Connect(function(child)
			if child:IsA("Tool") and child:FindFirstChild("BodyAttach") then
				M6D.Part1 = child.BodyAttach
			end
		end)
	end)

	player.CharacterRemoving:Connect(function(chara)
		--[[heart:Disconnect()
		heart2:Disconnect()]]
	end)

end)