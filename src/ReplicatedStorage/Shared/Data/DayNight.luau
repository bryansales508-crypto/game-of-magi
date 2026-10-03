--!strict
-- The look of the day: pure data for the client LightingController, the palette the world blends to at each moment of the shared clock. Timing (day and night length, dawn and dusk hours, blend time) is Config.World.DayNight. Day is the place's own Lighting, so nothing changes by day.

export type Palette = {
	Brightness: number,
	Ambient: Color3,
	OutdoorAmbient: Color3,
	AtmosphereDensity: number,
	AtmosphereColor: Color3,
	AtmosphereDecay: Color3,
	AtmosphereGlare: number,
	AtmosphereHaze: number,
	TintColor: Color3,
	ColorBrightness: number,
	Contrast: number,
	Saturation: number,
	BloomIntensity: number,
}

local DayNight = {}

DayNight.Day = {
	Brightness = 3,
	Ambient = Color3.fromRGB(46, 46, 46),
	OutdoorAmbient = Color3.fromRGB(69, 69, 69),
	AtmosphereDensity = 0.25,
	AtmosphereColor = Color3.fromRGB(250, 176, 97),
	AtmosphereDecay = Color3.fromRGB(92, 61, 13),
	AtmosphereGlare = 10,
	AtmosphereHaze = 0,
	TintColor = Color3.fromRGB(255, 201, 135),
	ColorBrightness = 0.01,
	Contrast = -0.1,
	Saturation = 0.2,
	BloomIntensity = 1,
} :: Palette

-- Long shadows, deeper orange, a little haze on the horizon.
DayNight.Dusk = {
	Brightness = 2,
	Ambient = Color3.fromRGB(40, 32, 30),
	OutdoorAmbient = Color3.fromRGB(80, 56, 44),
	AtmosphereDensity = 0.32,
	AtmosphereColor = Color3.fromRGB(240, 130, 70),
	AtmosphereDecay = Color3.fromRGB(110, 50, 20),
	AtmosphereGlare = 6,
	AtmosphereHaze = 1,
	TintColor = Color3.fromRGB(255, 180, 120),
	ColorBrightness = 0,
	Contrast = -0.05,
	Saturation = 0.15,
	BloomIntensity = 1.2,
} :: Palette

-- Dark but readable: cool blue ambient, low sky glare, no warm tint so the
-- city lights stand out.
DayNight.Night = {
	Brightness = 0.6,
	Ambient = Color3.fromRGB(22, 26, 40),
	OutdoorAmbient = Color3.fromRGB(34, 40, 62),
	AtmosphereDensity = 0.3,
	AtmosphereColor = Color3.fromRGB(120, 140, 190),
	AtmosphereDecay = Color3.fromRGB(30, 36, 60),
	AtmosphereGlare = 0,
	AtmosphereHaze = 1.5,
	TintColor = Color3.fromRGB(200, 210, 240),
	ColorBrightness = -0.02,
	Contrast = 0.05,
	Saturation = -0.1,
	BloomIntensity = 1.5,
} :: Palette

-- Pale gold coming back over the dunes.
DayNight.Dawn = {
	Brightness = 2,
	Ambient = Color3.fromRGB(40, 38, 44),
	OutdoorAmbient = Color3.fromRGB(80, 72, 70),
	AtmosphereDensity = 0.3,
	AtmosphereColor = Color3.fromRGB(250, 200, 140),
	AtmosphereDecay = Color3.fromRGB(90, 70, 50),
	AtmosphereGlare = 6,
	AtmosphereHaze = 1,
	TintColor = Color3.fromRGB(255, 220, 180),
	ColorBrightness = 0,
	Contrast = -0.05,
	Saturation = 0.1,
	BloomIntensity = 1.1,
} :: Palette

table.freeze(DayNight.Day)
table.freeze(DayNight.Dusk)
table.freeze(DayNight.Night)
table.freeze(DayNight.Dawn)
table.freeze(DayNight)

return DayNight
