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

local function fadeOutAndDestroy(sound: Sound, seconds: number)
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
	TweenService:Create(
		sound,
		TweenInfo.new(settings.CrossfadeSeconds, Enum.EasingStyle.Linear),
		{ Volume = volume }
	):Play()
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
	local sound = startSound(source, settings.Volume, looped)
	if sound == nil then
		return
	end
	current = sound
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

function MusicController.CurrentTrack(): string?
	return if current ~= nil then current.Name else nil
end

function MusicController:Init() end

function MusicController:Start()
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

	-- Regions may already have been entered before we subscribed.
	for _, key in RegionController.Current() do
		onEntered(key)
	end
end

return MusicController
