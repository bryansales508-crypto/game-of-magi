--!strict
-- Region music, ambient loops and the city banner (M6 Phase 6A,
-- docs/M6-PLAN.md). Replaces the old RegionHandlerPart1 + SoundController,
-- which cloned the whole soundtrack into every character and faded the wrong
-- way (AUDIT L21).
--
--  * Music: the highest-priority region we are in that has a playlist plays
--    it, shuffled without repeating the last track, crossfading between
--    tracks and on region change. One track just loops. Leaving every music
--    region fades to silence.
--  * Ambient: each region's `ambient` loop is its own layer, started on
--    enter and faded on leave, independent of the music.
--  * Banner: the MsgHold[CITY] template with the old bounce-in.
-- Tracks are Sounds under ReplicatedFirst.SFX.OSTs, cloned into one client
-- folder in SoundService (one soundtrack per client, not per life).

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Log = require(Shared:WaitForChild("Log"))
local Regions = require(Shared:WaitForChild("Data"):WaitForChild("Regions"))
local RegionController = require(script.Parent:WaitForChild("RegionController"))

local log = Log.new("MusicController")

local player = Players.LocalPlayer
local settings = Config.World.Music

local FORCED_KEY = "\0forced"
local NO_MUSIC_KEY = "\0none"

local MusicController = {}

-- FEAT-62: the player's own music volume (0-1), remembered for the session in
-- a client attribute so the panel and `.music` agree; Config is the default.
local VOLUME_ATTRIBUTE = "MusicVolume"
local userVolume: number = settings.Volume
local fadeTweens: { [Sound]: Tween } = {}
local changedCallbacks: { () -> () } = {}

local osts: Instance? = nil
local folder: Folder? = nil
local warnedTracks: { [string]: boolean } = {}

-- Music state. `activeKey` is the region (or a dev marker) the current
-- playlist belongs to; `current` is the sound now playing.
local activeKey: string? = nil
local playlist: { string } = {}
local current: Sound? = nil
local lastTrack: string? = nil
local ambientLayers: { [string]: Sound } = {}

local function notifyChanged()
	for _, callback in changedCallbacks do
		task.spawn(callback)
	end
end

local function fadeOutAndDestroy(sound: Sound, seconds: number)
	local running: Tween? = fadeTweens[sound]
	if running ~= nil then
		running:Cancel()
		fadeTweens[sound] = nil
	end
	local tween = TweenService:Create(sound, TweenInfo.new(seconds, Enum.EasingStyle.Linear), { Volume = 0 })
	tween.Completed:Once(function()
		sound:Destroy()
	end)
	tween:Play()
end

local function findTrack(name: string): Sound?
	local source = osts
	if source == nil then
		return nil
	end
	local track = source:FindFirstChild(name)
	if track ~= nil and track:IsA("Sound") then
		return track
	end
	if not warnedTracks[name] then
		warnedTracks[name] = true
		log:Warn("track not found under ReplicatedFirst.SFX.OSTs:", name)
	end
	return nil
end

local function startSound(source: Sound, volume: number, looped: boolean): Sound?
	local parent = folder
	if parent == nil then
		return nil
	end
	local sound = source:Clone()
	sound.Looped = looped
	sound.Volume = 0
	sound.Parent = parent
	sound:Play()
	local fade = TweenService:Create(
		sound,
		TweenInfo.new(settings.CrossfadeSeconds, Enum.EasingStyle.Linear),
		{ Volume = volume }
	)
	fadeTweens[sound] = fade
	fade.Completed:Once(function()
		fadeTweens[sound] = nil
	end)
	fade:Play()
	return sound
end

local function pickTrack(): string?
	local valid: { string } = {}
	for _, name in playlist do
		if findTrack(name) ~= nil then
			table.insert(valid, name)
		end
	end
	if #valid == 0 then
		return nil
	end
	if #valid == 1 then
		return valid[1]
	end
	local choice = valid[math.random(1, #valid)]
	while choice == lastTrack do
		choice = valid[math.random(1, #valid)]
	end
	return choice
end

local playNext

-- Called when the current track is about to end (or has). Ignored if the
-- sound it was scheduled for is no longer the current one.
local function advance(from: Sound)
	if current ~= from then
		return
	end
	playNext()
end

function playNext()
	local previous = current
	current = nil
	if previous ~= nil then
		fadeOutAndDestroy(previous, settings.CrossfadeSeconds)
	end
	notifyChanged()

	local name = pickTrack()
	if name == nil then
		return
	end
	local source = findTrack(name)
	if source == nil then
		return
	end
	lastTrack = name

	local looped = #playlist == 1
	local sound = startSound(source, userVolume, looped)
	if sound == nil then
		return
	end
	current = sound
	notifyChanged()
	if looped then
		return
	end

	-- Crossfade into the next track just before this one ends. Ended is the
	-- backstop if the length was not known yet.
	sound.Ended:Once(function()
		advance(sound)
	end)
	task.spawn(function()
		if not sound.IsLoaded then
			sound.Loaded:Wait()
		end
		local wait = sound.TimeLength - settings.CrossfadeSeconds
		if wait > 0 then
			task.delay(wait, advance, sound)
		end
	end)
end

local function setPlaylist(key: string?, tracks: { string })
	if key == activeKey then
		return
	end
	activeKey = key
	playlist = tracks
	if #tracks == 0 then
		local previous = current
		current = nil
		if previous ~= nil then
			fadeOutAndDestroy(previous, settings.CrossfadeSeconds)
		end
		notifyChanged()
		return
	end
	playNext()
end

local function refreshMusic()
	local bestKey: string? = nil
	for _, key in RegionController.Current() do
		local region = Regions[key]
		if region ~= nil and #region.playlist > 0 then
			bestKey = key
			break
		end
	end
	if bestKey == nil then
		setPlaylist(NO_MUSIC_KEY, {})
	else
		setPlaylist(bestKey, (Regions[bestKey] :: any).playlist)
	end
end

-- ==================== ambient layers ====================

local function startAmbient(key: string, ambient: { name: string, volume: number })
	if ambientLayers[key] ~= nil :: any then
		return
	end
	local source = findTrack(ambient.name)
	if source == nil then
		return
	end
	local sound = startSound(source, ambient.volume, true)
	if sound ~= nil then
		ambientLayers[key] = sound
	end
end

local function stopAmbient(key: string)
	local sound: Sound? = ambientLayers[key]
	if sound == nil then
		return
	end
	ambientLayers[key] = nil
	fadeOutAndDestroy(sound, settings.CrossfadeSeconds)
end

-- ==================== banner ====================

-- The old TranMsg: bounce in over 1 s, hold 5 s, drop out over 0.5 s.
local function animateBanner(label: GuiObject)
	local finalPosition = label.Position
	label.Position = finalPosition + UDim2.fromOffset(0, -100)
	TweenService:Create(label, TweenInfo.new(1, Enum.EasingStyle.Bounce), { Position = finalPosition }):Play()

	task.delay(5, function()
		if label.Parent == nil then
			return
		end
		local tween = TweenService:Create(
			label,
			TweenInfo.new(0.5, Enum.EasingStyle.Linear),
			{ Position = finalPosition + UDim2.fromOffset(0, -250) }
		)
		tween.Completed:Once(function()
			label:Destroy()
		end)
		tween:Play()
	end)
end

local function showBanner(title: string, subtitle: string)
	local gui = player:FindFirstChildOfClass("PlayerGui")
	local announcer = gui and gui:FindFirstChild("Announcer")
	local frame = announcer and announcer:FindFirstChild("AnnouncerFrame")
	local guiFolder = ReplicatedFirst:FindFirstChild("GUI")
	local msgTypes = guiFolder and guiFolder:FindFirstChild("MsgTypes")
	local template = msgTypes and msgTypes:FindFirstChild("MsgHold[CITY]")
	if frame == nil or template == nil then
		log:Warn("banner skipped: Announcer.AnnouncerFrame or MsgTypes[MsgHold[CITY]] missing")
		return
	end

	local banner = template:Clone()
	local cityTitle = banner:FindFirstChild("CityTitle")
	local description = banner:FindFirstChild("Description")
	if cityTitle == nil or not cityTitle:IsA("TextLabel") or description == nil or not description:IsA("TextLabel") then
		banner:Destroy()
		log:Warn("banner skipped: template lost its CityTitle/Description labels")
		return
	end
	cityTitle.Text = title
	description.Text = subtitle
	banner.Parent = frame

	animateBanner(cityTitle)
	animateBanner(description)
	task.delay(5.25, function()
		banner:Destroy()
	end)
end

-- ==================== region events ====================

local function onEntered(key: string)
	local region = Regions[key]
	if region == nil then
		return
	end
	if region.ambient ~= nil then
		startAmbient(key, region.ambient)
	end
	if region.banner ~= nil then
		showBanner(region.banner.title, region.banner.subtitle)
	end
	refreshMusic()
end

local function onLeft(key: string)
	stopAmbient(key)
	refreshMusic()
end

-- ==================== dev hooks (DevController) ====================

-- Plays one track on loop until the next region change.
function MusicController.PlayForced(name: string): boolean
	if findTrack(name) == nil then
		return false
	end
	activeKey = nil
	setPlaylist(FORCED_KEY, { name })
	return true
end

function MusicController.Stop()
	activeKey = nil
	setPlaylist(NO_MUSIC_KEY, {})
end

function MusicController.Next()
	if #playlist > 0 then
		playNext()
	end
end

-- Name of the track now playing, or nil.
function MusicController.Current(): string?
	return if current ~= nil then current.Name else nil
end

-- Resume the playlist of the region you are in (after Stop).
function MusicController.Play()
	if current == nil then
		activeKey = nil
		refreshMusic()
	end
end

function MusicController.IsPlaying(): boolean
	return current ~= nil
end

function MusicController.Volume(): number
	return userVolume
end

-- Live music volume (0-1), also applied to the track now playing and kept for
-- later tracks. Ambient layers keep their own volumes.
function MusicController.SetVolume(volume: number)
	userVolume = math.clamp(volume, 0, 1)
	player:SetAttribute(VOLUME_ATTRIBUTE, userVolume)
	local sound = current
	if sound ~= nil then
		local fade: Tween? = fadeTweens[sound]
		if fade ~= nil then
			fade:Cancel()
			fadeTweens[sound] = nil
		end
		sound.Volume = userVolume
	end
end

-- Called (deferred) whenever the track starts, changes or stops.
function MusicController.OnChanged(callback: () -> ())
	table.insert(changedCallbacks, callback)
end

-- ==================== music panel (FEAT-62) ====================

-- Bottom-left: track name, play/stop, volume slider. Bryan's board palette
-- (m2/m5c dumps: brown fill, orange accent, tan text, Merriweather Bold).
local PANEL_FILL = Color3.fromRGB(75, 54, 36)
local PANEL_ACCENT = Color3.fromRGB(229, 151, 62)
local PANEL_TEXT = Color3.fromRGB(255, 224, 152)

local function buildPanel()
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

	local gui = Instance.new("ScreenGui")
	gui.Name = "MusicPanel"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5
	gui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.AnchorPoint = Vector2.new(0, 1)
	frame.Position = UDim2.new(0, 12, 1, -12)
	frame.Size = UDim2.fromOffset(210, 62)
	frame.BackgroundColor3 = PANEL_FILL
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = PANEL_ACCENT
	stroke.Thickness = 1
	stroke.Parent = frame

	local boldFont = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Bold)

	local trackLabel = Instance.new("TextLabel")
	trackLabel.Name = "Track"
	trackLabel.BackgroundTransparency = 1
	trackLabel.Position = UDim2.fromOffset(10, 6)
	trackLabel.Size = UDim2.new(1, -66, 0, 24)
	trackLabel.FontFace = boldFont
	trackLabel.TextSize = 14
	trackLabel.TextColor3 = PANEL_TEXT
	trackLabel.TextXAlignment = Enum.TextXAlignment.Left
	trackLabel.TextTruncate = Enum.TextTruncate.AtEnd
	trackLabel.Text = "no music"
	trackLabel.Parent = frame

	local button = Instance.new("TextButton")
	button.Name = "PlayStop"
	button.AnchorPoint = Vector2.new(1, 0)
	button.Position = UDim2.new(1, -8, 0, 6)
	button.Size = UDim2.fromOffset(48, 24)
	button.BackgroundColor3 = PANEL_ACCENT
	button.BorderSizePixel = 0
	button.AutoButtonColor = true
	button.FontFace = boldFont
	button.TextSize = 13
	button.TextColor3 = Color3.new(0, 0, 0)
	button.Text = "Play"
	button.Parent = frame
	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(0, 4)
	buttonCorner.Parent = button

	local slider = Instance.new("Frame")
	slider.Name = "Slider"
	slider.Position = UDim2.fromOffset(10, 44)
	slider.Size = UDim2.new(1, -20, 0, 6)
	slider.BackgroundColor3 = Color3.fromRGB(40, 28, 18)
	slider.BorderSizePixel = 0
	slider.Parent = frame
	local sliderCorner = Instance.new("UICorner")
	sliderCorner.CornerRadius = UDim.new(1, 0)
	sliderCorner.Parent = slider

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = PANEL_ACCENT
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(userVolume, 1)
	fill.Parent = slider
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.fromScale(userVolume, 0.5)
	knob.Size = UDim2.fromOffset(12, 12)
	knob.BackgroundColor3 = PANEL_TEXT
	knob.BorderSizePixel = 0
	knob.Parent = slider
	local knobCorner = Instance.new("UICorner")
	knobCorner.CornerRadius = UDim.new(1, 0)
	knobCorner.Parent = knob

	-- A wider invisible hit area so the 6 px bar is easy to grab.
	local hit = Instance.new("TextButton")
	hit.Name = "Hit"
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.AnchorPoint = Vector2.new(0.5, 0.5)
	hit.Position = UDim2.fromScale(0.5, 0.5)
	hit.Size = UDim2.new(1, 12, 0, 24)
	hit.Parent = slider

	local function render()
		trackLabel.Text = MusicController.Current() or "no music"
		button.Text = if MusicController.IsPlaying() then "Stop" else "Play"
		fill.Size = UDim2.fromScale(userVolume, 1)
		knob.Position = UDim2.fromScale(userVolume, 0.5)
	end

	button.Activated:Connect(function()
		if MusicController.IsPlaying() then
			MusicController.Stop()
		else
			MusicController.Play()
		end
		render()
	end)

	local dragging = false
	local function setFromX(x: number)
		local width = slider.AbsoluteSize.X
		if width <= 0 then
			return
		end
		MusicController.SetVolume((x - slider.AbsolutePosition.X) / width)
		render()
	end
	hit.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = true
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if
			dragging
			and (
				input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch
			)
		then
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = false
		end
	end)

	MusicController.OnChanged(render)
	render()
end

function MusicController:Init() end

function MusicController:Start()
	local saved = player:GetAttribute(VOLUME_ATTRIBUTE)
	if typeof(saved) == "number" then
		userVolume = math.clamp(saved, 0, 1)
	else
		player:SetAttribute(VOLUME_ATTRIBUTE, userVolume)
	end

	local ostFolder = nil
	local sfx = ReplicatedFirst:WaitForChild("SFX", 30)
	if sfx ~= nil then
		ostFolder = sfx:WaitForChild("OSTs", 30)
	end
	if ostFolder == nil then
		log:Warn("ReplicatedFirst.SFX.OSTs not found; no music this session")
		return
	end
	osts = ostFolder

	local audio = Instance.new("Folder")
	audio.Name = "WorldAudio"
	audio.Parent = SoundService
	folder = audio

	RegionController.OnEntered(onEntered)
	RegionController.OnLeft(onLeft)

	task.spawn(buildPanel)

	-- Regions may already have been entered before we subscribed.
	for _, key in RegionController.Current() do
		onEntered(key)
	end
end

return MusicController
