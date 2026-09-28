--!strict
-- The shared day/night clock and the city lights (M6 Phase 6B,
-- docs/M6-PLAN.md).
--
-- Clock: the server (WorldClockService) sets Workspace attributes
--   DayStart  = server time (GetServerTimeNow) the day began, at DawnHour
--   DayLength = seconds for one whole in-game day (day part + night part)
--   DayPaused = optional number, an hour to freeze the clock at
-- Each client derives the hour from those every frame, so everyone sees the
-- same time and no network traffic exists. The day part (DawnHour to
-- DuskHour) spans DaySeconds and the night part NightSeconds of Config,
-- scaled together if DayLength differs from their sum (dev `.time speed`).
--
-- Palette: Day between dawn+Transition and dusk-Transition, Dusk at
-- DuskHour, Night, Dawn at DawnHour, blended over TransitionSeconds on each
-- side (Shared/Data/DayNight.luau).
--
-- City lights: anything tagged Config.World.DayNight.Tag (a part or a
-- model) has its lights, fires and particles on at night and off by day,
-- and its Neon parts go DayMaterial by day.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Log = require(Shared:WaitForChild("Log"))
local DayNight = require(Shared:WaitForChild("Data"):WaitForChild("DayNight"))

local log = Log.new("LightingController")

local clock = Config.World.DayNight
type Palette = DayNight.Palette

local LightingController = {}

-- ==================== palette blending ====================

local atmosphere: Atmosphere? = nil
local colorCorrection: ColorCorrectionEffect? = nil
local bloom: BloomEffect? = nil
local appliedKey: string? = nil

local function apply(a: Palette, b: Palette, t: number)
	Lighting.Brightness = a.Brightness + (b.Brightness - a.Brightness) * t
	Lighting.Ambient = a.Ambient:Lerp(b.Ambient, t)
	Lighting.OutdoorAmbient = a.OutdoorAmbient:Lerp(b.OutdoorAmbient, t)

	local atm = atmosphere
	if atm ~= nil then
		atm.Density = a.AtmosphereDensity + (b.AtmosphereDensity - a.AtmosphereDensity) * t
		atm.Color = a.AtmosphereColor:Lerp(b.AtmosphereColor, t)
		atm.Decay = a.AtmosphereDecay:Lerp(b.AtmosphereDecay, t)
		atm.Glare = a.AtmosphereGlare + (b.AtmosphereGlare - a.AtmosphereGlare) * t
		atm.Haze = a.AtmosphereHaze + (b.AtmosphereHaze - a.AtmosphereHaze) * t
	end
	local cc = colorCorrection
	if cc ~= nil then
		cc.TintColor = a.TintColor:Lerp(b.TintColor, t)
		cc.Brightness = a.ColorBrightness + (b.ColorBrightness - a.ColorBrightness) * t
		cc.Contrast = a.Contrast + (b.Contrast - a.Contrast) * t
		cc.Saturation = a.Saturation + (b.Saturation - a.Saturation) * t
	end
	local bl = bloom
	if bl ~= nil then
		bl.Intensity = a.BloomIntensity + (b.BloomIntensity - a.BloomIntensity) * t
	end
end

-- `seconds` is the position in the cycle: 0 = dawn, daySeconds = dusk.
local function applyPalette(seconds: number, daySeconds: number, totalSeconds: number)
	local w = math.min(clock.TransitionSeconds, daySeconds * 0.5, (totalSeconds - daySeconds) * 0.5)
	local key: string
	local a: Palette
	local b: Palette
	local t = 0
	if w <= 0 then
		-- No blending configured: hard switch.
		a = if seconds < daySeconds then DayNight.Day else DayNight.Night
		b = a
		key = if seconds < daySeconds then "Day" else "Night"
	elseif seconds < w then
		a, b, t, key = DayNight.Dawn, DayNight.Day, seconds / w, ""
	elseif seconds < daySeconds - w then
		a, b, key = DayNight.Day, DayNight.Day, "Day"
	elseif seconds < daySeconds then
		a, b, t, key = DayNight.Day, DayNight.Dusk, (seconds - (daySeconds - w)) / w, ""
	elseif seconds < daySeconds + w then
		a, b, t, key = DayNight.Dusk, DayNight.Night, (seconds - daySeconds) / w, ""
	elseif seconds < totalSeconds - w then
		a, b, key = DayNight.Night, DayNight.Night, "Night"
	else
		a, b, t, key = DayNight.Night, DayNight.Dawn, (seconds - (totalSeconds - w)) / w, ""
	end

	-- Steady Day / Night: nothing to write after the first time.
	if key ~= "" then
		if appliedKey == key then
			return
		end
		appliedKey = key
	else
		appliedKey = nil
	end
	apply(a, b, t)
end

-- ==================== city lights ====================

type Item = {
	instance: Instance,
	kind: "Light" | "Emitter" | "Neon",
	brightness: number, -- lights: authored Brightness
	enabled: boolean, -- lights/emitters: authored Enabled
	material: Enum.Material, -- neon parts: authored material
	tween: Tween?,
}

type Entry = {
	items: { [Instance]: Item },
	connections: { RBXScriptConnection },
}

local entries: { [Instance]: Entry } = {}
local cityOn = false
local forcedState: boolean? = nil
local warnedMissing: { [string]: boolean } = {}

local EMITTER_CLASSES = { "Fire", "Smoke", "Sparkles", "ParticleEmitter" }

local function isEmitter(instance: Instance): boolean
	for _, className in EMITTER_CLASSES do
		if instance:IsA(className) then
			return true
		end
	end
	return false
end

local function applyItem(item: Item, on: boolean, animate: boolean)
	local instance = item.instance
	if item.tween ~= nil then
		item.tween:Cancel()
		item.tween = nil
	end
	if item.kind == "Neon" then
		(instance :: BasePart).Material = if on then item.material else clock.DayMaterial
	elseif item.kind == "Emitter" then
		(instance :: any).Enabled = on and item.enabled
	else
		local light = instance :: Light
		if not animate then
			light.Brightness = if on then item.brightness else 0
			light.Enabled = on and item.enabled
		elseif on then
			light.Enabled = item.enabled
			local tween = TweenService:Create(
				light,
				TweenInfo.new(clock.LightFadeSeconds, Enum.EasingStyle.Linear),
				{ Brightness = item.brightness }
			)
			item.tween = tween
			tween:Play()
		else
			local tween = TweenService:Create(
				light,
				TweenInfo.new(clock.LightFadeSeconds, Enum.EasingStyle.Linear),
				{ Brightness = 0 }
			)
			item.tween = tween
			tween.Completed:Once(function(state)
				if state == Enum.PlaybackState.Completed then
					light.Enabled = false
				end
			end)
			tween:Play()
		end
	end
end

local function restoreItem(item: Item)
	if item.tween ~= nil then
		item.tween:Cancel()
		item.tween = nil
	end
	local instance = item.instance
	if item.kind == "Neon" then
		(instance :: BasePart).Material = item.material
	elseif item.kind == "Emitter" then
		(instance :: any).Enabled = item.enabled
	else
		local light = instance :: Light
		light.Brightness = item.brightness
		light.Enabled = item.enabled
	end
end

local function addItem(entry: Entry, instance: Instance)
	if entry.items[instance] ~= nil then
		return
	end
	local item: Item? = nil
	if instance:IsA("Light") then
		item = {
			instance = instance :: Instance,
			kind = "Light",
			brightness = instance.Brightness,
			enabled = instance.Enabled,
			material = Enum.Material.Plastic,
			tween = nil,
		}
	elseif isEmitter(instance) then
		item = {
			instance = instance :: Instance,
			kind = "Emitter",
			brightness = 0,
			enabled = (instance :: any).Enabled,
			material = Enum.Material.Plastic,
			tween = nil,
		}
	elseif instance:IsA("BasePart") and instance.Material == Enum.Material.Neon then
		-- Only parts that are Neon when found are ever touched.
		item = {
			instance = instance :: Instance,
			kind = "Neon",
			brightness = 0,
			enabled = true,
			material = Enum.Material.Neon,
			tween = nil,
		}
	end
	if item ~= nil then
		entry.items[instance] = item
		applyItem(item, cityOn, false)
	end
end

local function removeItem(entry: Entry, instance: Instance)
	local item = entry.items[instance]
	if item ~= nil then
		entry.items[instance] = nil
		restoreItem(item)
	end
end

local function registerRoot(root: Instance)
	if entries[root] ~= nil then
		return
	end
	local entry: Entry = { items = {}, connections = {} }
	entries[root] = entry
	addItem(entry, root)
	for _, descendant in root:GetDescendants() do
		addItem(entry, descendant)
	end
	table.insert(
		entry.connections,
		root.DescendantAdded:Connect(function(descendant)
			addItem(entry, descendant)
		end)
	)
	table.insert(
		entry.connections,
		root.DescendantRemoving:Connect(function(descendant)
			removeItem(entry, descendant)
		end)
	)
end

local function unregisterRoot(root: Instance)
	local entry = entries[root]
	if entry == nil then
		return
	end
	entries[root] = nil
	for _, connection in entry.connections do
		connection:Disconnect()
	end
	for _, item in entry.items do
		restoreItem(item)
	end
end

local function setCityState(on: boolean, animate: boolean)
	if cityOn == on then
		return
	end
	cityOn = on
	for _, entry in entries do
		for _, item in entry.items do
			applyItem(item, on, animate)
		end
	end
end

-- Dev: force the lamps on or off (nil releases them back to the clock).
function LightingController.ForceLights(state: boolean?)
	forcedState = state
end

function LightingController.LightsOn(): boolean
	return cityOn
end

-- ==================== the clock ====================

local function cycle(): (number?, number, number)
	-- Returns seconds into the cycle (nil while the server clock is not
	-- there yet), the scaled day-part length and the whole-day length.
	local total = clock.DaySeconds + clock.NightSeconds
	local length = Workspace:GetAttribute("DayLength")
	local scale = 1
	if type(length) == "number" and length > 0 then
		scale = length / total
	end
	local daySeconds = clock.DaySeconds * scale
	local totalSeconds = total * scale

	local paused = Workspace:GetAttribute("DayPaused")
	if type(paused) == "number" then
		-- Frozen at an hour: turn it into the matching position in the cycle.
		local dayHours = clock.DuskHour - clock.DawnHour
		local hour = (paused - clock.DawnHour) % 24
		if hour < dayHours then
			return hour / dayHours * daySeconds, daySeconds, totalSeconds
		end
		return daySeconds + (hour - dayHours) / (24 - dayHours) * (totalSeconds - daySeconds), daySeconds, totalSeconds
	end

	local start = Workspace:GetAttribute("DayStart")
	if type(start) ~= "number" then
		return nil, daySeconds, totalSeconds
	end
	return (Workspace:GetServerTimeNow() - start) % totalSeconds, daySeconds, totalSeconds
end

local function hourAt(seconds: number, daySeconds: number, totalSeconds: number): number
	local dayHours = clock.DuskHour - clock.DawnHour
	if seconds < daySeconds then
		return clock.DawnHour + seconds / daySeconds * dayHours
	end
	local nightFraction = (seconds - daySeconds) / (totalSeconds - daySeconds)
	return (clock.DuskHour + nightFraction * (24 - dayHours)) % 24
end

local lastClockTime = -1
local synced = false

local function step()
	local seconds, daySeconds, totalSeconds = cycle()
	if seconds == nil then
		return
	end
	local hour = hourAt(seconds, daySeconds, totalSeconds)
	if math.abs(hour - lastClockTime) > 0.001 then
		lastClockTime = hour
		Lighting.ClockTime = hour
	end
	applyPalette(seconds, daySeconds, totalSeconds)

	local wantOn = seconds >= daySeconds
	if forcedState ~= nil then
		wantOn = forcedState
	end
	-- The first reading snaps (a night joiner sees lit lamps at once); after
	-- that dusk and dawn fade.
	setCityState(wantOn, synced)
	synced = true
end

local function findEffects()
	atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	colorCorrection = Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
	bloom = Lighting:FindFirstChildOfClass("BloomEffect")
	local function warnMissing(name: string, found: Instance?)
		if found == nil and not warnedMissing[name] then
			warnedMissing[name] = true
			log:Warn("Lighting has no", name, "- that part of the palette is skipped")
		end
	end
	warnMissing("Atmosphere", atmosphere)
	warnMissing("ColorCorrection", colorCorrection)
	warnMissing("Bloom", bloom)
end

function LightingController:Init() end

function LightingController:Start()
	findEffects()

	-- Apply the current state once, without waiting a frame, so a night
	-- joiner sees lit lamps straight away.
	cityOn = false
	for _, root in CollectionService:GetTagged(clock.Tag) do
		registerRoot(root)
	end
	CollectionService:GetInstanceAddedSignal(clock.Tag):Connect(registerRoot)
	CollectionService:GetInstanceRemovedSignal(clock.Tag):Connect(unregisterRoot)

	-- The server may set the attributes a moment after we join.
	if type(Workspace:GetAttribute("DayStart")) ~= "number" and type(Workspace:GetAttribute("DayPaused")) ~= "number" then
		log:Debug("waiting for the server clock (Workspace DayStart)")
	end
	step()
	RunService.RenderStepped:Connect(step)
end

return LightingController
