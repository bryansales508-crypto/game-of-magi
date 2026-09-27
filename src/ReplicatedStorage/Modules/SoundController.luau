local sfx = {}

--ts
local ts = game:GetService("TweenService")

function sfx.MainControl(chara, name, vol, spd)
	local sFolder = chara.Torso:FindFirstChild("SoundsFolder")

	local music = sFolder:FindFirstChild(name):Clone()

	if vol == nil then vol = 0.5 end
	music.Volume = 0

	if spd == nil then spd = 1 end
	music.PlaybackSpeed = spd

	local tween = ts:Create(music, TweenInfo.new(1, Enum.EasingStyle.Linear), {Volume = vol})

	-- PlayingMusic
	local folder

	while chara:FindFirstChild("DeletingMusic") do
		task.wait(0.1)
	end

	if not chara.Torso:FindFirstChild("PlayingMusic") then
		folder = Instance.new("Folder")
		folder.Name = "PlayingMusic"
		folder.Parent = chara.Torso
	end

	music.Parent = chara.Torso:WaitForChild("PlayingMusic")

	music:Play()
	tween:Play()
	
	if not chara.Torso.PlayingMusic:FindFirstChild("PlaylistOn") then
		music.Looped = true
	end
end

function sfx.CutOff(chara, name)
	local plymusic = chara.Torso:FindFirstChild("PlayingMusic")
	if plymusic then
		if name == "All" then
			local DeletingMusic = Instance.new("IntValue")
			DeletingMusic.Name = "DeletingMusic"
			DeletingMusic.Parent = chara

			for _,i in plymusic:GetChildren() do
				if i.Name == "PlaylistOn" then
					i.Value = "Left Region"
					
					delay(0.25, function()
						i:Destroy()
					end)
				else
					local tween = ts:Create(i, TweenInfo.new(1, Enum.EasingStyle.Linear), {Volume = 0})
					tween.Completed:Connect(function()
						i:Destroy()
					end)
					tween:Play()
				end
			end
			
			while #plymusic:GetChildren() == 0 do
				task.wait()
			end
			plymusic:Destroy()
			DeletingMusic:Destroy()
		elseif name ~= nil then
			local tween = ts:Create(plymusic:FindFirstChild(name), TweenInfo.new(1, Enum.EasingStyle.Linear), {Volume = 0})
			tween.Completed:Connect(function()
				plymusic:FindFirstChild(name):Destroy()
			end)
			tween:Play()
		end
	end
end

function sfx.CutDown(chara, name, vol)
	local plymusic = chara.Torso:FindFirstChild("PlayingMusic")
	if plymusic then
		if name ~= "All" then
			local music = plymusic:FindFirstChild("Name")

			music.Volume = vol 
		else
			if vol == "Half" then
				for _,i in plymusic:GetChildren() do
					if not i:FindFirstChild("OriginalVolume") then
						local ab = tonumber(tostring(i.Volume))

						local OGVol = Instance.new("NumberValue")
						OGVol.Name = "OriginalVolume"
						OGVol.Value = ab
						OGVol.Parent = i
					end

					i.Volume = i.Volume/2
				end
			else
				for _,i in plymusic:GetChildren() do
					i.Volume = vol
				end
			end
		end
	end
end

function sfx.Restore(chara)
	local plymusic = chara.Torso:FindFirstChild("PlayingMusic")
	if plymusic then
		for _,i in plymusic:GetChildren() do
			if i:FindFirstChild("OriginalVolume") then
				i.Volume = i.OriginalVolume.Value
			end

			if i:FindFirstChild("Muffle") then
				local tween = ts:Create(i:FindFirstChild("Muffle"), TweenInfo.new(1, Enum.EasingStyle.Linear), {HighGain = 0, MidGain = 0})
				tween:Play()

				tween.Completed:Connect(function()
					i:FindFirstChild("Muffle"):Destroy()
				end)
			end
		end
	end
end

function sfx.Muffle(chara, name)
	local plymusic = chara.Torso:FindFirstChild("PlayingMusic")
	if plymusic then
		if name == "All" then
			for _,i in plymusic:GetChildren() do
				if not i:FindFirstChild("Muffle") then
					local muffle = Instance.new("EqualizerSoundEffect")
					muffle.Name = "Muffle"
					muffle.HighGain = 0
					muffle.MidGain = 0
					muffle.LowGain = 0
					muffle.Parent = i

					local v
					if i.Name == "SnowAmbi" then v = -20 else v = -10 end

					local tween = ts:Create(muffle, TweenInfo.new(0.75, Enum.EasingStyle.Linear), {HighGain = v, MidGain = v})
					tween:Play()
				end
			end
		else
			local music = plymusic:FindFirstChild(name)

			local muffle = Instance.new("EqualizerSoundEffect")
			muffle.Name = "Muffle"

			if music.Name == "SnowAmbi" then
				muffle.HighGain = -20
				muffle.MidGain = -20
			else
				muffle.HighGain = -10
				muffle.MidGain = -10
			end

			muffle.Parent = music
		end
	end
end

function sfx.Playlist(chara)
	local playingmusic = chara:WaitForChild("Torso"):WaitForChild("PlayingMusic")
	local playlist = {}

	for _,music in playingmusic:GetChildren() do
		if not string.find(music.Name, "Ambi") then
			table.insert(playlist, music)

			music:Destroy()
		end
	end

	if not playingmusic:FindFirstChild("PlaylistOn") then
		local PlaylistOn = Instance.new("StringValue")
		PlaylistOn.Name = "PlaylistOn"
		PlaylistOn.Parent = playingmusic
	end

	local musicDB = true

	local OldSong = nil

	while playingmusic:FindFirstChild("PlaylistOn") and musicDB do
		-- Debounce
		musicDB = false
		local loopfinished = false
		
		-- Setting up Breaking Loop on Change
		playingmusic:FindFirstChild("PlaylistOn").Changed:Connect(function(v)
			if v == "Left Region" then
				loopfinished = true
			end
		end)

		-- Music Repeat Function
		local function MusicPlay()
			local currentMusic = playlist[math.random(1, #playlist)]

			-- Making Sure New Song
			while OldSong == currentMusic do
				task.wait()
				currentMusic = playlist[math.random(1, #playlist)]
			end

			OldSong = currentMusic

			-- Playing Song
			local c = currentMusic:Clone()
			c.Parent =  chara.Torso:FindFirstChild("PlayingMusic")
			
			-- Volume
			local tween = ts:Create(c, TweenInfo.new(1, Enum.EasingStyle.Linear), {Volume = 0.05})
			
			c:Play()
			tween:Play()

			-- Waiting for Sound to Load
			if not c.IsLoaded then 
				c.Loaded:Wait()
			end
			
			-- Determing Length
			local PlayTime = c.TimeLength

			-- TODO: Interweave with low health song and combat music.

			delay(PlayTime, function()
				c:Destroy()

				-- Debounce
				musicDB = true

				if loopfinished == false then
					MusicPlay()
				end
			end)
		end

		-- Calling Function and Breaking
		if loopfinished == true then
			break
		else
			MusicPlay()
		end
	end
end
--TODO: Make a true playlist, of various types. Eventual compability with other playing songs.

return sfx
