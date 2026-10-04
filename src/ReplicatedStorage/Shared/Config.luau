--!strict
-- Shared configuration, read by both server and client. One frozen table; every tunable number lives here.

local RunService = game:GetService("RunService")

local Config = {}

Config.IsStudio = RunService:IsStudio()

Config.Debug = {
	Enabled = Config.IsStudio,
	FreshSave = false,
	SaveScope = if Config.IsStudio then "Studio" else "Live",
	LogLevel = if Config.IsStudio then "Debug" else "Info",
	-- Speeds up aging and day/night for tests; 1 = real time.
	TimeScale = 1,
	-- Off by default in Studio so dev aging (.age/.birthday) never kills a test character; always on live.
	-- DevService.IsMortal() is the runtime override (Config is frozen).
	DeathRolls = not Config.IsStudio,
}

Config.Data = {
	StoreName = "GameOfMagi_v1",
	-- Schema history lives in SaveSchema.Migrations; bump SchemaVersion together with a new migration.
	SchemaVersion = 5,
}

-- UserIds that always count as devs. Any player also counts as a dev while Config.Debug.Enabled (Studio); see DevService.IsDev.
Config.Dev = {
	Admins = { 27938432 },
}

-- Aging. AgeService multiplies the online tick's banked seconds by DevService.GetTimeScale(); offline aging is always real time.
-- SceneTimeout is real time too: the client's scene takes the same wall-clock time at any aging speed.
Config.Aging = {
	SecondsPerYear = if Config.IsStudio then 60 else 1800,
	OfflineYearsPerDay = 2,
	OfflineAgeCap = 59,
	AdultAge = 18,
	GreyStart = 45,
	GreyEnd = 70,
	-- From DeathStart, every online birthday carries a heart-attack moment; DeathChance is the odds it is fatal, linearly interpolated between points.
	DeathStart = 60,
	DeathChance = {
		{ 60, 0.05 },
		{ 65, 0.10 },
		{ 70, 0.20 },
		{ 75, 0.35 },
		{ 80, 0.50 },
		{ 90, 0.80 },
		{ 100, 1.0 },
	},
	-- How long the server waits for RukhSceneDone before starting the new
	-- life anyway.
	SceneTimeout = 30,
	Tick = 10,
}

-- Lives per character before a real death (Humanoid.Died: falling, the void, drowning) wipes to a brand-new character. A combat knockout never touches this. See Character.LivesLeft and LifeService.
Config.Life = {
	LivesPerCharacter = 4,
	-- How long a death with lives left waits before respawning the same character.
	RespawnDelay = 3,
	-- LifeService sets Players.RespawnTime to this. Every death is respawned by our own code (RespawnDelay, AgeService after the Rukh scene on the last life, or the join pipeline), so this is only a far-off safety net; the engine default would respawn a last-life character mid-scene.
	EngineRespawnSeconds = 3600,
}

-- Max health and block.
Config.Health = {
	Base = 50,
	HeightBonus = 3,
	-- Indexed by Ranks.rankFor's rank index (1 = Street Rat .. 7 = King/Queen).
	RankBonus = { 0, 10, 20, 35, 50, 70, 100 },
	RegenPerSecond = { Idle = 2, Combat = 0, Knocked = 1 },
	MaxBlock = 100,
	BlockRegenPerSecond = 10,
	Tick = 1,
	-- CombatService.SetTier(player, "Combat") on any hit dealt or taken; falls back to "Idle" after this many seconds without combat activity. "Knocked" always wins while active.
	CombatTierSeconds = 6,
}

-- Animation-driven, per-style hit chain (Shared/Data/Combat.luau's Combat.Styles shape). Per-hit numbers (damage, hit windows, stun) live in Combat.luau; pacing, assets and feel are here.
-- A combo is one animation but takes one click per hit: the animation freezes at each hit's wind-up marker until the player clicks again. The chain loops while each click lands inside HitGap..ClickTimeout of the previous hit.
Config.Combat = {
	-- Seconds of slack added to both ends of a hit's hitWindow when the server checks an AttackHit report (and to AttackCancel's windows and AttackContinue's HitGap/ClickTimeout), absorbing network and animation-marker jitter.
	HitTolerance = 0.15,
	-- Chain pacing, in seconds. The server enforces all of these; the client mirrors them so a click that cannot count is never sent. The chain ends by dropping (no click in time), a cancel, an interrupt, or an NPC finishing its pass.
	Chain = {
		-- Earliest the next hit's click counts after a hit lands. An earlier click is remembered and fires when the gap is over, so mashing never drops a hit but cannot speed it up.
		HitGap = 0.2,
		-- Latest the next hit's click counts; past this the combo is dropped (DropRecovery applies).
		ClickTimeout = 1.0,
		-- Cooldown before a new chain can start after one ends any way other than a drop: an NPC finishing its pass, a cancel after at least one hit, or the watchdog giving up on a hit report.
		Recovery = 0.25,
		-- Cooldown after a chain times out, counted from the moment it is dropped.
		DropRecovery = 0.2,
		-- Server watchdog margin: how long past a hit's hitWindow.max (+ HitTolerance) the server waits for the client's report before silently ending the attack with Recovery.
		WatchdogMargin = 0.6,
	},
	-- Marker (animation event) names in each style's combo animation: one Windup and one Hit name per hit, in order. With LogMarkers on, CombatController logs every KeyframeReached and configured marker with track time and seconds since that hit's segment started.
	Markers = {
		Fist = {
			Windup = { "WindUp1", "WindUp2" },
			Hit = { "Punch1", "Punch2" },
		},
		Dagger = {
			Windup = { "Windup1", "Windup2", "Windup3" },
			Hit = { "Hit1", "Hit2", "Hit3" },
		},
	},
	LogMarkers = true,
	-- How long EffectsController flashes the "Cancel" Highlight for a cancelled attack.
	CancelFlashSeconds = 0.25,
	-- Combat stance toggle key. Clicks, Block and cancel only work while InCombat (a click with a weapon Tool equipped enters the stance first).
	StanceKey = Enum.KeyCode.C,
	-- Every combat animation asset id lives here (CombatController and EffectsController read them). StanceAnimations: one looping idle per style, played on any InCombat character; empty = none yet.
	StanceAnimations = {
		Fist = "rbxassetid://124480069742107",
		Dagger = "",
	},
	StanceSpeed = 0.1,
	-- One combo animation per style, containing the style's whole chain in order (Fist: WindUp1, Punch1, WindUp2, Punch2).
	ComboAnimations = {
		Fist = "rbxassetid://104341608277955",
		Dagger = "rbxassetid://115894342135428",
	},
	-- Playback speed of each combo animation outside its wind-ups (1 = as authored).
	ComboSpeed = {
		-- Retune Combat.luau's Fist windows whenever this changes; its comments show the arithmetic.
		Fist = 1.3,
		Dagger = 0.25,
	},
	-- Dash lines (EffectsController): Count thin copies of ReplicatedFirst.VFX.MiscEffects.DashTrail sprout from random points in the torso's box (scaled by Spread, 1 = whole box), each MinWidth..MaxWidth studs tall, for Seconds.
	DashTrail = {
		Count = 7,
		Seconds = 0.3,
		Spread = 0.9,
		MinWidth = 0.08,
		MaxWidth = 0.3,
	},
	-- Block pose, run and the four cardinal dashes.
	MoveAnimations = {
		Block = "rbxassetid://15429144750",
		Run = "rbxassetid://15421855688",
		DashForward = "rbxassetid://18100686685",
		DashLeft = "rbxassetid://18101513350",
		DashBack = "rbxassetid://18101228314",
		DashRight = "rbxassetid://18101385205",
	},
	-- The server's CombatUnlocked attribute is the real source of truth; the client only reads it. Every new life starts unlocked until a tutorial exists (Meta.Unlocks.Combat survives DataService.NewLife; only Wipe clears it).
	UnlockedByDefault = true,
	LockedMessageSeconds = 2,
}

-- Locomotion animations: CharacterService writes them into a player's Animate script, and NpcAnimController plays the same ones on every NPC.
Config.Character = {
	Animations = {
		Idle = "rbxassetid://15422107398",
		Walk = "rbxassetid://15421859266",
		Run = "rbxassetid://15421855688",
		Jump = "rbxassetid://15428492106",
		Fall = "rbxassetid://15428818320",
	},
}

-- The heart-attack/death scene's sound.
Config.Sfx = {
	Heartbeat = "rbxassetid://102383912898742",
}

-- Timings for the heart-attack pulses and the return-to-the-Rukh scene. The scene's look (colours, the AfterLife model) lives in RukhController and ReplicatedFirst.AfterLife.
Config.Scene = {
	-- A heartbeat is "lub-dub": BeatGap is the gap between the two beats, PairGap the pause after the pair (seconds).
	BeatGap = 0.25,
	PairGap = 0.8,
	NonFatalCycles = 2,
	FatalCycles = 3,
	-- Each fatal cycle's BeatGap/PairGap is multiplied by this again (compounding), so beats slow and pauses grow.
	FatalSlowFactor = 1.4,
	MessageSeconds = 2,
	-- Return-to-the-Rukh walk: total time, and how much of its end is the fade to white.
	WalkSeconds = 6,
	FadeSeconds = 2,
	-- How far ahead of the spawn point the stand-in core sits when the AfterLife model has no AfterlifeCore (studs).
	CoreDistance = 15,
}

-- NpcService/AiController. NPCs are combatants like players; MaxHealth comes from here by NpcType instead of the rank ladder.
Config.Npc = {
	TickSeconds = 0.2,
	ChaseRadius = 30,
	GiveUpRadius = 40,
	AttackRange = 4,
	AttackCooldown = 1.4,
	-- Seconds after an NPC chain hit lands before it throws the next one. Must be at least Combat.Chain.HitGap and under ClickTimeout, or its combos get dropped.
	ContinueDelay = 0.35,
	WanderRadius = 12,
	MaxHealth = { Dummy = 100, Target = 100 },
	-- The Target NPC (the one that chases and punches): gripsOnKnockout makes it walk up and grip a player it knocked out (GripService). Turn it off to have it just stand over them. It only grips someone it knocked out itself, and after a broken grip waits regripCooldownSeconds before trying again (a hit on it buys the victim that long). Trainers never grip.
	Target = { gripsOnKnockout = true, regripCooldownSeconds = 3 },
	-- Optional fallback asset ids for walk/run/flinch; the model's own Animation instances (by name, see Trees.luau) are tried first.
	Animations = { Walk = "", Run = "", Flinch = "" },
	-- The seven training dummies, all Fist style. reactionSeconds: delay before reacting to the player's attributes (CurrentHitIndex/Attacking). rhythmSeconds: pace of a dummy that throws on its own schedule. weights: Sparring Sinbad's throw/cancel/parry/dash mix. engageRadius: a trainer only fights its spawner or the nearest player within this many studs. All values are placeholders to tune.
	Trainers = {
		StraightSam = {
			displayName = "Straight Sam",
			rhythmSeconds = 2.5,
			engageRadius = 12,
		},
		TurtleTariq = {
			displayName = "Turtle Tariq",
			engageRadius = 12,
		},
		JabbingJamal = {
			displayName = "Jabbing Jamal",
			reactionSeconds = 0.3,
			engageRadius = 12,
		},
		ParryPete = {
			displayName = "Parry Pete",
			reactionSeconds = 0.3,
			engageRadius = 12,
		},
		FeintingMohammed = {
			displayName = "Feinting Mohammed",
			rhythmSeconds = 2.5,
			engageRadius = 12,
		},
		DashingDalila = {
			displayName = "Dashing Dalila",
			reactionSeconds = 0.25,
			rhythmSeconds = 2.5,
			engageRadius = 12,
		},
		SparringSinbad = {
			displayName = "Sparring Sinbad",
			rhythmSeconds = 2.0,
			engageRadius = 12,
			weights = { throw = 0.4, cancel = 0.2, parry = 0.2, dash = 0.2 },
		},
	},
	-- Teaching order; also `.dummy list`'s print order, since Lua tables keep none.
	TrainerOrder = {
		"StraightSam",
		"TurtleTariq",
		"JabbingJamal",
		"ParryPete",
		"FeintingMohammed",
		"DashingDalila",
		"SparringSinbad",
	},
}

-- Delivery missions. OpenStuds/BoardCloseStuds give the board hysteresis (open near the part, close only once well clear); ArriveStuds is the same for the destination part. PlayerActiveThreshold is checked against the player's Progress.Routes count and SafeRouteThreshold against each city's static Safety value.
Config.Missions = {
	OpenStuds = 12,
	BoardCloseStuds = 20,
	ArriveStuds = 10,
	PlayerActiveThreshold = 10,
	SafeRouteThreshold = 0.75,
	TimeCrunchSeconds = 180,
	-- An interception only pays if the courier is genuinely out on the route (this far from the start, or this far into the run), so two accounts cannot farm it by knocking a courier out beside the board.
	InterceptMinStuds = 100,
	InterceptMinSeconds = 30,
	-- Intercepted mark: every interception adds one stack to the courier (Progress.Intercepted). MissionService.OfferMultiplier = max(InterceptedFloor, InterceptedDecay ^ stacks) scales that player's board offers, their payout for a marked delivery, and an interceptor's payout while the victim is marked (no Black Rukh either). One completed delivery clears every stack after paying at the reduced rate.
	InterceptedDecay = 0.5,
	InterceptedFloor = 0.1,
	HeavyCargoSpeedMult = 0.75,
	-- HeavyCargo's package model is scaled up by this (Model:ScaleTo on attach).
	HeavyCargoPackScale = 1.5,
	MagoiPerDelivery = 10,
	-- Where a city's placeholder drop-off goes when its `<key>Delivery` part is missing and Workspace.Regions has no `<key>REGION` part. A city with neither refuses runs.
	PlaceholderDeliveryPoints = {
		Qarzin = Vector3.new(1761.86, 199.22, -7571.19),
		Saleh = Vector3.new(-2459.5, 197.41, -8458.78),
		Rathole = Vector3.new(-5064, 97.05, -6700.53),
		JaddatysHut = Vector3.new(-6364.55, 197.41, -8423.13),
		IllegalPort = Vector3.new(-159.21, 295.15, -5313.41),
		Sahraqin = Vector3.new(7400.8, 186.67, -7302),
		AinJamala = Vector3.new(3779.3, 197.41, -8866.13),
	} :: { [string]: Vector3 },
	-- How often the shared board/run loop ticks (arrival checks, TimeCrunch expiry, the beacon).
	Tick = 0.5,
	-- Courier beacon: a Highlight visible through walls (DepthMode AlwaysOnTop), drawn by the client off the CourierBeacon character attribute that MissionService toggles every everySeconds for forSeconds. The client fades in/out over 0.6 s each way inside the window.
	Beacon = {
		everySeconds = 45,
		forSeconds = 3,
	},
}

-- Bounty hunting. A player is wanted (huntable, postered) at PostingThreshold or more; taking a bounty needs rank index RankGateIndex (3 = Adventurer, Data/Ranks). The server pins one poster per wanted player to the BountyBoard, highest bounty first, at most MaxPosters. CityRefreshSeconds: how often the server re-reads each wanted player's last known city (a rough report, not live tracking). Taking a bounty gives a "Bounty: <name>" Tool; while it is equipped the server tracks every Tracking.TickSeconds: within ReachStuds of the last known spot, the last known spot follows the target; within RevealStuds of the target, they are revealed; once revealed, staying beyond RevealStuds for LoseSeconds loses them again. Reward (Data/Bounty): Copper = the bounty, Magoi = MagoiBase + bounty / MagoiDivisor capped at MagoiCap, GoldRukhDeeds Gold Rukh deeds.
Config.Bounty = {
	PostingThreshold = 20,
	RankGateIndex = 3,
	CityRefreshSeconds = 20,
	MaxPosters = 8,
	-- The board is the first BasePart under Workspace named BoardName (or BoardAltName) that has a Decal named FrontDecalName; the Decal's Face is the side posters go on. Poster Width/Height (studs) shrink to fit when the board is small.
	BoardName = "QuestBoard",
	BoardAltName = "BountyBoard",
	FrontDecalName = "frontface",
	Poster = {
		Width = 6,
		Height = 6,
		-- The portrait: the camera's field of view (degrees, smaller = closer) and how long a look change (clothes, respawn) settles before the clone is rebuilt.
		PortraitFov = 30,
		PortraitSettleSeconds = 0.75,
	},
	Tracking = {
		TickSeconds = 1,
		ReachStuds = 25,
		RevealStuds = 80,
		LoseSeconds = 6,
	},
	-- Carrying a knocked-out player (CarryService): pick-up reach, walk speed while carrying, how long the carried stay knocked after a drop, where the body rides (Offset from the carrier's torso, TiltDegrees of roll so it lies across the shoulder), and how often the carry refreshes the Knocked status.
	Carry = {
		ReachStuds = 6,
		SpeedMult = 0.6,
		GraceSeconds = 4,
		Offset = Vector3.new(0.6, 1.4, 0),
		TiltDegrees = 90,
		RefreshSeconds = 0.5,
		DropDistance = 4,
	},
	-- Gripping a knocked-out player to kill them (GripService). ReachStuds: how close the gripper must be to start. Seconds: how long the choke takes; TickSeconds: how often progress is sent and the victim kept down. BreakDistance: how far the gripper may be pushed from where they started before it breaks. GraceSeconds: extra Knocked the victim gets when a grip is broken. BlackRukh: Black deeds every completed grip gives the gripper. Animations: asset ids for the gripper/victim poses once they exist (the client poses it in code until then).
	Grip = {
		ReachStuds = 5,
		Seconds = 4,
		TickSeconds = 0.25,
		BreakDistance = 3,
		GraceSeconds = 2,
		BlackRukh = 1,
		Animations = { Gripper = "", Victim = "" },
	},
	-- The jail (JailService). Sentence = bounty * SecondsPerBountyPoint clamped to MinSeconds..MaxSeconds. A prisoner outside the cell bounds is put back, checked every TickSeconds. PlaceholderOffset: where the placeholder cell (used only when no real jail is found) sits from the city's region centre.
	Jail = {
		-- Bryan's jail: the first Workspace descendant named JailFolderName that has a DropoffName part and a CellFolderName folder holding a SpawnName part. The cell's bounds are every part under CellFolderName, grown by BoundsMargin studs; leaving them (or being teleported out) puts the prisoner back at the spawn.
		JailFolderName = "Jail",
		DropoffName = "JailDropoff",
		CellFolderName = "LargeCell",
		SpawnName = "JailSpawn",
		BoundsMargin = 2,
		-- ReachStuds: how far from the dropoff part's box a hunter may stand to hand someone over.
		ReachStuds = 8,
		SecondsPerBountyPoint = 6,
		MinSeconds = 60,
		MaxSeconds = 600,
		TickSeconds = 1,
		PlaceholderOffset = Vector3.new(40, 0, 40),
	},
	Reward = {
		MagoiBase = 25,
		MagoiDivisor = 4,
		MagoiCap = 50,
		GoldRukhDeeds = 1,
	},
}

-- The Rukh flutter on RankUp/AlignmentChanged. Emitters are ParticleEmitter names under ReplicatedFirst.VFX.RukhEffects; EmitRate multiplies every cloned emitter's own Rate.
Config.Rukh = {
	FlutterSeconds = 4,
	EmitRate = 1,
	Emitters = {
		White = { "SpecialRukh1", "SpecialRukh2", "SpecialRukh3" },
		Gold = { "Rukh1", "Rukh2", "Rukh3" },
		Black = { "DepravityRukh1", "DepravityRukh2", "DepravityRukh3" },
		GoldBlack = { "Rukh1", "Rukh2", "DepravityRukh1", "DepravityRukh2" },
	},
}

table.freeze(Config.Debug)
table.freeze(Config.Data)
table.freeze(Config.Dev.Admins)
table.freeze(Config.Dev)
for _, point in Config.Aging.DeathChance do
	table.freeze(point)
end
table.freeze(Config.Aging.DeathChance)
table.freeze(Config.Aging)
table.freeze(Config.Life)
table.freeze(Config.Health.RankBonus)
table.freeze(Config.Health.RegenPerSecond)
table.freeze(Config.Health)
table.freeze(Config.Combat.Markers.Fist.Windup)
table.freeze(Config.Combat.Markers.Fist.Hit)
table.freeze(Config.Combat.Markers.Fist)
table.freeze(Config.Combat.Markers.Dagger.Windup)
table.freeze(Config.Combat.Markers.Dagger.Hit)
table.freeze(Config.Combat.Markers.Dagger)
table.freeze(Config.Combat.Markers)
table.freeze(Config.Combat.Chain)
table.freeze(Config.Combat.StanceAnimations)
table.freeze(Config.Combat.ComboAnimations)
table.freeze(Config.Combat.ComboSpeed)
table.freeze(Config.Combat.MoveAnimations)
table.freeze(Config.Combat)
table.freeze(Config.Character.Animations)
table.freeze(Config.Character)
table.freeze(Config.Sfx)
table.freeze(Config.Scene)
table.freeze(Config.Npc.MaxHealth)
table.freeze(Config.Npc.Animations)
table.freeze(Config.Npc.Target)
table.freeze(Config.Npc.Trainers.StraightSam)
table.freeze(Config.Npc.Trainers.TurtleTariq)
table.freeze(Config.Npc.Trainers.JabbingJamal)
table.freeze(Config.Npc.Trainers.ParryPete)
table.freeze(Config.Npc.Trainers.FeintingMohammed)
table.freeze(Config.Npc.Trainers.DashingDalila)
table.freeze(Config.Npc.Trainers.SparringSinbad.weights)
table.freeze(Config.Npc.Trainers.SparringSinbad)
table.freeze(Config.Npc.Trainers)
table.freeze(Config.Npc.TrainerOrder)
table.freeze(Config.Npc)
table.freeze(Config.Rukh.Emitters.White)
table.freeze(Config.Rukh.Emitters.Gold)
table.freeze(Config.Rukh.Emitters.Black)
table.freeze(Config.Rukh.Emitters.GoldBlack)
table.freeze(Config.Rukh.Emitters)
table.freeze(Config.Rukh)
table.freeze(Config.Missions.Beacon)
table.freeze(Config.Missions.PlaceholderDeliveryPoints)
table.freeze(Config.Missions)
table.freeze(Config.Bounty.Tracking)
table.freeze(Config.Bounty.Poster)
table.freeze(Config.Bounty.Carry)
table.freeze(Config.Bounty.Grip.Animations)
table.freeze(Config.Bounty.Grip)
table.freeze(Config.Bounty.Jail)
table.freeze(Config.Bounty.Reward)
table.freeze(Config.Bounty)

-- The world: music, the shared day clock, the ocean and footsteps. The night look lives in Shared/Data/DayNight.luau, region playlists in Shared/Data/Regions.luau.
Config.World = {
	Music = {
		-- One volume for every playlist track. Ambient loops keep their own volume in Regions.luau.
		Volume = 0.5,
		CrossfadeSeconds = 1,
		RegionPollSeconds = 0.25,
	},
	DayNight = {
		-- 10 real minutes of daylight (06:00 to 18:00) and 6 of night. Day must stay longer than night. Total = one in-game day.
		DaySeconds = 600,
		NightSeconds = 360,
		DawnHour = 6,
		DuskHour = 18,
		-- How long the palette blends at dawn and dusk, and how long a tagged city light takes to fade on or off (seconds).
		TransitionSeconds = 60,
		LightFadeSeconds = 2,
		-- CollectionService tag for a lamp, torch or fire part or model: its lights, fires and particles run at night only, and a Neon part in it swaps to DayMaterial by day.
		Tag = "CityLight",
		DayMaterial = Enum.Material.SmoothPlastic,
	},
	Ocean = {
		-- Off until the old wave scripts under Workspace.MAP.OCEAN are deleted; they would fight the client for the tile positions.
		Enabled = false,
		-- Tiles rise Amplitude studs over RiseSeconds, hold, then fall; wave decals fade in, out, then pause.
		Amplitude = 2,
		RiseSeconds = 15,
		HoldSeconds = 3,
		DecalFadeSeconds = 10,
		DecalPauseSeconds = 10,
		DecalVisibleTransparency = 0.95,
		CullDistance = 6000,
	},
	Footsteps = {
		-- Footstep volumes while walking and running.
		WalkVolume = 0.1,
		RunVolume = 0.25,
		-- Sand and mud prints: how long one stays and how far below the torso the raycast looks for the ground (studs).
		PrintSeconds = 0.75,
		PrintRayStuds = 6,
		-- true logs every step event, floor material and sound picked, to debug silent steps.
		Debug = false,
		-- Fallback when Animate's walk markers don't fire: one step per this many studs walked. 0 = off.
		FallbackStrideStuds = 5.5,
		-- Seconds between running steps. 0 = follow the run animation (one step each half of its loop); a number overrides that.
		RunStepSeconds = 0,
	},
	-- Dash sound name, under ReplicatedFirst.SFX.CombatSounds.
	Sfx = {
		Dash = "QuickDash",
	},
}
table.freeze(Config.World.Music)
table.freeze(Config.World.DayNight)
table.freeze(Config.World.Ocean)
table.freeze(Config.World.Footsteps)
table.freeze(Config.World.Sfx)
table.freeze(Config.World)
table.freeze(Config)

return Config
