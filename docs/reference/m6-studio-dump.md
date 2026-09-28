# M6 Studio Dump

Read-only survey of the TEST place (Studio id `aae8c2b7-dc47-4284-8705-688de422a1b9`) taken 2026-09-28 by the playtester, in Edit mode. No instances were changed. This is raw reference material for M6 planning, not analysis.

## 1. Regions

`Workspace.Regions` folder structure and every descendant:

| Path | Class | Size | Position | CanCollide | Transparency | Name has "REGION" |
|---|---|---|---|---|---|---|
| Workspace.Regions.Ocean | Folder | — | — | — | — | no |
| Workspace.Regions.Ocean.OceanREGION | Part | 2048.0, 203.8, 602.0 | -25.9, 59.9, -559.1 | false | 1.00 | yes |
| Workspace.Regions.Ocean.OceanREGION | Part | 755.5, 203.8, 363.5 | 397.3, 59.9, 92.3 | false | 1.00 | yes |
| Workspace.Regions.Ocean.OceanREGION | Part | 1450.6, 203.8, 551.5 | 714.3, 59.9, 455.4 | false | 1.00 | yes |
| Workspace.Regions.Ocean.OceanREGION | Part | 546.3, 203.8, 243.0 | 21.0, 59.9, -136.8 | false | 1.00 | yes |
| Workspace.Regions.Qarzin | Folder | — | — | — | — | no |
| Workspace.Regions.Qarzin.QarzinREGION | Part | 387.7, 623.3, 342.9 | 1674.2, 269.6, -7682.4 | false | 1.00 | yes |
| Workspace.Regions.Qarzin.QarzinREGION | Part | 583.8, 623.3, 770.0 | 2132.2, 269.6, -7430.2 | false | 1.00 | yes |
| Workspace.Regions.SakuraIslandREGION | Part | 583.8, 623.3, 767.3 | 0.0, 269.6, 123.9 | false | 1.00 | yes |

All region parts are `CanCollide=false`, `Transparency=1` (invisible triggers).

Region-named parts elsewhere in Workspace (outside `Workspace.Regions`): **0 found** (`workspace:GetDescendants()` name-filtered on `"REGION"`).

## 2. Ocean

Path: `Workspace.MAP.OCEAN`

Child structure by depth from `OCEAN`:

| Depth | Classes and counts |
|---|---|
| 1 | Folder = 256 |
| 2 | Part = 1279 |
| 3 | Script = 511, Decal = 255 |
| 4 | Script = 255 |

Each of the 256 `Folder`s under `OCEAN` contains a mix of parts named:

| Part name | Count | Has child script |
|---|---|---|
| Baseplate | 768 | none |
| MovingPart | 256 | `Waves` (256 total) |
| OceanWaves | 255 | `Waves` (255 total), plus a `Decal` child holding a `DecalWaves` script (255 total) |

All 1279 parts are **Anchored = true**. They sit on **4 distinct Y levels** (not one shared level): `-33, -32, -31.4, -19.6` (rounded to 1 decimal).

Sample part (`Workspace.MAP.OCEAN.Folder.OceanWaves`): Size = 2048.0, 153.9, 2048.0; Position = -2076.0, -19.6, -5266.0; Material = Glass; Transparency = 1.00; Anchored = true.

**`Waves` script under a `MovingPart`** (`Workspace.MAP.OCEAN.Folder.MovingPart.Waves`, verbatim, one copy of 256):
```lua
local ts = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local up = ts:Create(script.Parent, TweenInfo.new(15,Enum.EasingStyle.Linear,Enum.EasingDirection.In), {CFrame = script.Parent.CFrame + Vector3.new(0,2,0)})
local down = ts:Create(script.Parent, TweenInfo.new(15,Enum.EasingStyle.Linear,Enum.EasingDirection.In), {CFrame = script.Parent.CFrame + Vector3.new(0,-2,0)})

local Moving = false

RunService.Heartbeat:Connect(function(dt)
	if Moving then return
	else
		Moving = true
		up:Play()
		up.Completed:Connect(function()
			task.wait(3)
			down:Play()
			down.Completed:Connect(function()
				Moving = false
			end)
		end)
	end
end)
```

**`Waves` script under an `OceanWaves` part** (`Workspace.MAP.OCEAN.Folder.OceanWaves.Waves`, verbatim, one copy of 255):
```lua
local ts = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local up = ts:Create(script.Parent, TweenInfo.new(15,Enum.EasingStyle.Linear,Enum.EasingDirection.In), {CFrame = script.Parent.CFrame + Vector3.new(0,2,0)})
local down = ts:Create(script.Parent, TweenInfo.new(15,Enum.EasingStyle.Linear,Enum.EasingDirection.In), {CFrame = script.Parent.CFrame + Vector3.new(0,2,0)})

local Moving = false

RunService.Heartbeat:Connect(function(dt)
	if Moving then return
	else
		Moving = true
		up:Play()
		up.Completed:Connect(function()
			task.wait(3)
			down:Play()
			down.Completed:Connect(function()
				Moving = false
			end)
		end)
	end
end)
```
Note (observed, not fixed): this copy's `down` tween target is identical to `up`'s (`+Vector3.new(0,2,0)` both times) — likely a copy/paste bug, so this variant only moves up, never back down. Flag for AUDIT if M6 touches ocean systems.

**`DecalWaves` script** (`Workspace.MAP.OCEAN.Folder.OceanWaves.Decal.DecalWaves`, verbatim, one copy of 255):
```lua
local ts = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local fade = ts:Create(script.Parent, TweenInfo.new(10,Enum.EasingStyle.Linear,Enum.EasingDirection.In), {Transparency = 0.95})
local fadeOut = ts:Create(script.Parent, TweenInfo.new(10,Enum.EasingStyle.Linear,Enum.EasingDirection.In), {Transparency = 1})

local Fading = false

RunService.Heartbeat:Connect(function(dt)
	if Fading then return
	else
		Fading = true
		task.wait(10)
		fade:Play()
		fade.Completed:Connect(function()
			fadeOut:Play()
			fadeOut.Completed:Connect(function()
				Fading = false
			end)
		end)
	end
end)
```

Each of the 1279 ocean parts runs its own `Heartbeat`-connected script — 766 live connections total (256 + 255 + 255), each doing per-frame tween-state checks. Worth flagging as a perf/architecture concern for any M6 ocean rework.

## 3. Lighting and sky

`game.Lighting` properties:

| Property | Value |
|---|---|
| ClockTime | 13.5156 |
| TimeOfDay | 13:30:56 |
| Brightness | 3 |
| Ambient | 0.18, 0.18, 0.18 |
| OutdoorAmbient | 0.27, 0.27, 0.27 |
| ColorShift_Top | 0.00, 0.00, 0.00 |
| ColorShift_Bottom | 0.00, 0.00, 0.00 |
| EnvironmentDiffuseScale | 1 |
| EnvironmentSpecularScale | 1 |
| ExposureCompensation | 0 |
| FogColor | 0.75, 0.75, 0.75 |
| FogStart | 0 |
| FogEnd | 100000 (effectively no fog) |
| GlobalShadows | true |
| ShadowSoftness | 0.2 |
| Technology | not readable (script lacks `RobloxScript` capability from execute_luau context) |

Children of Lighting:

- **Sky**: SkyboxBk/Dn/Ft/Lf/Rt/Up all `rbxasset://textures/sky/sky512_*.tex` (Roblox default skybox, not a custom one). SunTextureId = `rbxasset://sky/sun.jpg`, MoonTextureId = `rbxasset://sky/moon.jpg` (also defaults).
- **Atmosphere**: Density = 0.25, Offset = 0, Color = 0.98, 0.69, 0.38 (warm/orange), Decay = 0.36, 0.24, 0.05, Glare = 10, Haze = 0.
- **BloomEffect** "Bloom": Intensity = 1, Size = 15, Threshold = 0.8, Enabled = true.
- **ColorCorrectionEffect** "ColorCorrection": Brightness = 0.01, Contrast = -0.1, Saturation = 0.2, TintColor = 1.00, 0.79, 0.53 (warm tint), Enabled = true.
- **SunRaysEffect** "SunRays": Intensity = 0.115, Spread = 0.45, Enabled = true.
- **DepthOfFieldEffect** "DepthOfField": FarIntensity = 0.75, FocusDistance = 0.05, InFocusRadius = 250, NearIntensity = 0.75, Enabled = true.

Scripts that set `ClockTime` or `TimeOfDay` (script_grep, paths only):

- `ServerStorage.Folder.Day/Night Cycle` — sets `lighting.ClockTime = 12` then tweens to 18, 24, 6 (day/night cycle driver). This is the only script found; `TimeOfDay` is never set directly anywhere.

## 4. City lights and fires

Whole-Workspace counts for the target classes (recursive from `workspace`):

| Class | Count |
|---|---|
| PointLight | 6 |
| SpotLight | 0 |
| SurfaceLight | 0 |
| Fire | 0 |
| Smoke | 0 |
| Sparkles | 0 |
| ParticleEmitter | 28 (none have an ancestor named Torch/Lamp/Lantern/Fire/Candle/Brazier/Campfire) |

All 6 `PointLight`s, grouped by top-level model:

| Top-level model | Class | Count | Brightness | Range | Color | Enabled (T/F) | Parent part (Material) |
|---|---|---|---|---|---|---|---|
| Workspace.Qarzin.Lighting | PointLight | 3 | 1.00 | 42.0 | 0.31, 0.49, 0.71 (blue) | 3/0 | BackR_bulb (Neon) |
| Workspace.Qarzin.Building3 | PointLight | 3 | 1.00 | 42.0 | 0.31, 0.49, 0.71 (blue) | 3/0 | BackR_bulb (Neon) |

Neon-material parts under `Workspace.Qarzin` and `Workspace.MAP`:

| Model | Color | Count |
|---|---|---|
| Workspace.Qarzin.Building3 | 1.00, 0.77, 0.47 (warm gold) | 2 |
| Workspace.Qarzin.Building3 | 0.35, 0.55, 0.80 (blue) | 1 |
| Workspace.Qarzin.Lighting | 1.00, 0.77, 0.47 (warm gold) | 3 |
| Workspace.MAP.* | — | 0 |

**Takeaway for M6:** the city has essentially no baked lighting — only 6 PointLights total (all in two Qarzin models) and 6 Neon parts across the whole map. There are no Fire/Smoke/Sparkles instances and no torch/lamp/lantern/brazier/campfire particle effects anywhere in Workspace. "City lights and fires" as a system is effectively unbuilt, not broken — worth a DESIGN.md conversation with Bryan rather than a fix.

## 5. Sounds

Sound instance counts by root:

| Root | Sound count |
|---|---|
| ReplicatedFirst | 62 |
| ReplicatedStorage | 0 |
| SoundService | 0 |
| StarterPlayer | 0 |

All 62 sounds live under `ReplicatedFirst.SFX`, organized into subfolders: `RukhSounds` (2), `OSTs` (10, background music + ambience), `MiscSounds` (2), `Steps` (8, footstep variants per surface), `CombatSounds` (24: SwordMissSounds, SwordHitSounds, SkillSounds, HitSounds), `Magic` (8: Heat, Sound, Strength categories), `UISounds` (2).

Full path / SoundId / Volume / Looped / "Ambi" in name:

| Path | SoundId | Volume | Looped | Ambi? |
|---|---|---|---|---|
| SFX.RukhSounds.MagiJoin | 16438077413 | 0.10 | false | no |
| SFX.RukhSounds.RukhSound | 16438069717 | 0.50 | true | no |
| SFX.OSTs.LowHealthAmbi | 16425755329 | 0.50 | true | **yes** |
| SFX.OSTs.Tostarena Ruins | 17111309889 | 0.50 | true | no |
| SFX.OSTs.Sentiment Actuel 01 | 16850765452 | 0.50 | true | no |
| SFX.OSTs.Notre Empire Dévastation | 16850756596 | 0.50 | true | no |
| SFX.OSTs.Danse Bizzare | 17111313493 | 0.50 | true | no |
| SFX.OSTs.L'imminence | 16850773701 | 0.50 | true | no |
| SFX.OSTs.Paix D'espirit | 17111300734 | 0.50 | true | no |
| SFX.OSTs.Gerudo Town Day | 17111298461 | 0.50 | true | no |
| SFX.OSTs.RainAmbi | 17270520733 | 0.50 | true | **yes** |
| SFX.OSTs.Die | 135877143815572 | 0.50 | false | no |
| SFX.OSTs.Lullaby | (empty SoundId) | 0.50 | true | no |
| SFX.OSTs.We Did It | 134480257649638 | 0.50 | true | no |
| SFX.OSTs.Resort Island | 82914123931465 | 0.50 | true | no |
| SFX.OSTs.OceanAmbi | 134436736678869 | 0.50 | true | **yes** |
| SFX.MiscSounds.CoinReward | 16822536394 | 0.50 | false | no |
| SFX.MiscSounds.BreathIn | 18306276602 | 0.35 | false | no |
| SFX.Steps.LeftSnow / RightSnow | 15848547713 / 15848545768 | 0.30 | false | no |
| SFX.Steps.LeftCarpet / RightCarpet | 15848543058 / 15848541089 | 0.30 | false | no |
| SFX.Steps.LeftBlock / RightBlock | 15848743100 / 15848741740 | 0.30 | false | no |
| SFX.Steps.RightDirt / LeftDirt | 108059534932911 / 75941472707985 | 0.30 | false | no |
| SFX.CombatSounds.QuickDash | 18100952809 | 0.25 | false | no |
| SFX.CombatSounds.SwordMissSounds.SwordMissSound1/2/3 | 18112149161 / 18112150875 / 18112152256 | 0.35 | false | no |
| SFX.CombatSounds.SwordHitSounds.SwordHitSound1 | 18115714142 | 0.35 | false | no |
| SFX.CombatSounds.SwordHitSounds.SwordHitSound2 | 18115715353 | 0.35 | false | no |
| SFX.CombatSounds.SwordHitSounds.SwordHitSound3 | 18115714142 (same asset as Sound1) | 0.35 | false | no |
| SFX.CombatSounds.SwordHitSounds.SwordClangSound1 | 18320620776 | **3.00** | false | no |
| SFX.CombatSounds.SwordHitSounds.SwordClangSound2 | 18320618401 | 0.50 | false | no |
| SFX.CombatSounds.SkillSounds.BattleCry[M] | 18310260804 | **5.00** | false | no |
| SFX.CombatSounds.SkillSounds.BattleCry[F] | 18310259387 | **5.00** | false | no |
| SFX.CombatSounds.HitSounds.BlockSound1/2 | 15430209636 / 15430208295 | 0.35 | false | no |
| SFX.CombatSounds.HitSounds.BlockBroken | 15430217404 | 0.35 | false | no |
| SFX.CombatSounds.HitSounds.LightHitSound1/2/3/Fin | 15418720501 / 15418721640 / 15418722795 / 15418723761 | 0.35 | false | no |
| SFX.CombatSounds.HitSounds.MissSound1/2/3 | 15437431400 / 15437428819 / 15437541549 | 0.35 | false | no |
| SFX.CombatSounds.HitSounds.GroundBreak | 16129086247 | 0.50 | false | no |
| SFX.CombatSounds.HitSounds.Parry | 102171521296052 | 0.35 | false | no |
| SFX.Magic.Heat.ContinousFlame1 | 18384753674 | 0.35 | false | no |
| SFX.Magic.Heat.InitialFlame1 | 18384747360 | 0.50 | false | no |
| SFX.Magic.Heat.FlameExplosion1 | 18384756649 | 0.50 | false | no |
| SFX.Magic.MagicActivation1 | 18410178701 | 0.10 | false | no |
| SFX.Magic.WandFlick | (empty SoundId) | 0.35 | false | no |
| SFX.Magic.Sound.SoundMagicBuild | 18413242845 | 0.35 | false | no |
| SFX.Magic.Sound.MusicalRelease1 | 18413239677 | 0.50 | false | no |
| SFX.Magic.Strength.EarthRumble | 18502573575 | 0.40 | false | no |
| SFX.Magic.Strength.EarthBreak | 18502571105 | 0.30 | false | no |
| SFX.UISounds.SelectSound1 | 109404634254122 | 0.25 | false | no |
| SFX.UISounds.SelectSound2 | 127398501421639 | 0.25 | false | no |

Notable: `SFX.OSTs.Lullaby` and `SFX.Magic.WandFlick` have empty `SoundId` (unassigned). `SwordClangSound1` (Volume 3.00) and both `BattleCry` sounds (Volume 5.00) are far louder than everything else (0.10–0.50 range) — likely needs normalizing, flag for AUDIT if M6 touches combat audio.

`SoundService` properties: AmbientReverb = NoReverb, DistanceFactor = 3.33, RespectFilteringEnabled = true. No SoundGroups exist.

## 6. GUI templates for M6

`ReplicatedFirst.GUI.MsgTypes` children:

- **MsgHold[BLACKALERT]** (Frame, Size={1,0},{1,0}, Pos={0.5,0},{0.1,0})
  - TempMsg (TextLabel, Size={0,200},{0,50}, Pos={0.5,0},{0.5,0}, Font=Unknown, TextColor=0.00,0.00,0.00 (black), TextSize=29, Text="the al-thamen has set their eyes upon you.")
- **MsgHold[REDALERT]** (Frame, Size={1,0},{1,0}, Pos={0.5,0},{0.1,0})
  - TempMsg (TextLabel, Size={0,200},{0,50}, Pos={0.5,0},{0.5,0}, Font=Unknown, TextColor=0.78,0.15,0.15 (red), TextSize=29, Text="the stench of black rukh, you are in danger.")
- **MsgHold[CITY]** (Frame, Size={1,0},{1,0}, Pos={0.5,0},{0.1,0}) — full verbatim as requested:
  - CityTitle (TextLabel, Size={0,200},{0,50}, Pos={0.5,0},{0.5,0}, Font=Unknown, TextColor=0.75,0.74,0.48 (tan/gold), TextSize=56, Text="Q A R Z I N")
  - Description (TextLabel, Size={0,200},{0,50}, Pos={0.70,0},{0.80,0}, Font=Unknown, TextColor=1.00,1.00,1.00 (white), TextSize=14, Text="The Merchant's Playground")

Note: `Font` reads as `Enum.Font.Unknown` for all three templates via this API — likely a `FontFace`-based custom font rather than a legacy `Enum.Font` value; worth a manual Studio check if font matters for M6 GUI work.

## 7. Collisions

`workspace.MAP` direct children: `BADLANDS` (Folder), `OCEAN` (Folder), `MISSION` (Folder), `Spawns` (Folder), `SAKURAISLAND` (Folder).

`workspace.MAP.Areas` does **not** exist.

Total BaseParts under `MAP`: **2064**.

PhysicsService registered collision groups (`GetRegisteredCollisionGroups()`): only **Default** is registered (`id=nil` reported — likely the default group's id wasn't surfaced by this API call, but no custom groups are registered via PhysicsService).

Parts per CollisionGroup found on parts under Workspace (note: parts can carry a CollisionGroup name even if PhysicsService's registry call didn't list it — these are read from each part's `.CollisionGroup` property directly):

| Collision Group | Part count |
|---|---|
| Default | 4483 |
| MapCollisionGroup | 101 |
| iiBryCollisionLimbs | 36 |
| RebornNoMoreCollisionGroup-HRT | 16 |
| RebornNoMoreCollisionGroupHRT | 2 |

Note: `RebornNoMoreCollisionGroup-HRT` and `RebornNoMoreCollisionGroupHRT` (with/without hyphen) look like a naming split from remake-leftover code — two near-identical group names, only 16 + 2 parts total. Worth checking if this is intentional or a typo during any M6 collision work.

## 8. Day/Night Cycle script

`ServerStorage.Folder.Day/Night Cycle` — ClassName = `Script`, Disabled = `false`.

Full verbatim source:
```lua
-- Services
local lighting = game:GetService("Lighting")
local tweenService = game:GetService("TweenService")

-- Objects
local settingsDir = script.Settings

function getSetting (name)
	return settingsDir and settingsDir:FindFirstChild(name) and settingsDir[name].Value
end

function tween (l, p)
	tweenService:Create(lighting, TweenInfo.new(l, Enum.EasingStyle.Linear, Enum.EasingDirection.In), p):Play()
end

function isCustomLightingAllowed ()
	
	local lFix = game:GetService("ServerScriptService"):FindFirstChild("Realism Mod"):FindFirstChild("LightingFix")
	
	if lFix then
		return not lFix.Disabled
	end
end

-- Variables
local dayDuration = (getSetting("Day duration") or 10) * 60 -- How many real-time minutes an in-game day will last
local nightDuration = (getSetting("Night duration") or 6) * 60 -- How many real-time minutes an in-game night will last

lighting.ClockTime = 12

while type(dayDuration) == "number" and type(nightDuration) == "number" do
	
	tween(dayDuration, {ClockTime = 18})
	wait(dayDuration)
	
	-- Change colors only with 'LightingFix' enabled
	if isCustomLightingAllowed() then
		tween(4, {OutdoorAmbient = Color3.fromRGB(60, 60, 60), FogColor = Color3.fromRGB(25, 25, 25), FogEnd = 250})
	end
		
	tween(nightDuration / 2, {ClockTime = 24})
	wait(nightDuration / 2)
	tween(nightDuration / 2, {ClockTime = 6})
	wait(nightDuration / 2)
	
	-- Change colors only with 'LightingFix' enabled
	if isCustomLightingAllowed() then
		tween(4, {OutdoorAmbient = Color3.fromRGB(140, 140, 140), FogColor = Color3.fromRGB(195, 195, 195), FogEnd = 750})
	end
end
```

Note: `dayDuration`/`nightDuration` read from `script.Settings` (a values folder under the script), defaulting to 10 and 6 *real-time minutes* respectively if unset. The color-shift tweens (`OutdoorAmbient`/`FogColor`/`FogEnd`) only run if `ServerScriptService."Realism Mod".LightingFix` exists and is not Disabled — another remake-leftover-style dependency worth checking during M6.

Other children of `ServerStorage.Folder` (names and classes only):

| Name | Class |
|---|---|
| Skills | Folder |
| Spells | Folder |
| Items | Folder |
| MagicItems | Folder |
| Weapons | Folder |
| Spells | Folder (duplicate name) |
| DeathHandlerPart2 | Script |
| CurrencyHandler | Script |
| InteractionsHandler | Script |
| LeaderBoardMaster | Script |
| DevControlPart2 | Script |
| AnnouncerPart2 | Script |
| PartyHandlerPart2 | Script |
| CarriageAndEscort | Script |
| BountyAndJail | Script |
| Day/Night Cycle | Script |
| Skills/Techniques | Folder |
| PartyHandlerPart1 | LocalScript |
| MissionHandler | LocalScript |
| DeathHandlerPart1 | LocalScript |
| AnnouncerPart1 | LocalScript |
| SpellWork | LocalScript |
| WipeHandlerPart2 | LocalScript |

Note: two folders are both named "Spells" — worth flagging for SYSTEMS.md/AUDIT if not already known. Also note several scripts and LocalScripts sit directly in `ServerStorage.Folder` rather than in a `Server`/`Client` script container — these are presumably cloned into place at runtime (a common Part1/Part2 remake pattern) rather than running from ServerStorage directly, since ServerStorage doesn't execute scripts in place.
