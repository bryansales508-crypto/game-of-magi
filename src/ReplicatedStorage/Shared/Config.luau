--!strict
-- Shared configuration, read by both server and client.
--
-- One frozen table. Later milestones add their own sections here
-- (Aging, Rank, Economy, ...) alongside Debug and Data. Don't invent
-- those sections yet.

local RunService = game:GetService("RunService")

local Config = {}

Config.IsStudio = RunService:IsStudio()

Config.Debug = {
	Enabled = Config.IsStudio,
	-- M1-03: forces a brand-new save every time DataService loads, in Studio only.
	FreshSave = false,
	SaveScope = if Config.IsStudio then "Studio" else "Live",
	LogLevel = if Config.IsStudio then "Debug" else "Info",
	-- Speeds up aging and day/night for tests; 1 = real time.
	TimeScale = 1,
	-- BUG-20 (Bryan, design): off by default in Studio, so dev aging
	-- (.age/.birthday) never accidentally kills a test character; always
	-- on live. DevService.IsMortal() is the runtime override (.mortal
	-- on|off), same pattern as TimeScale, since Config is frozen.
	DeathRolls = not Config.IsStudio,
}

Config.Data = {
	StoreName = "GameOfMagi_v1",
	-- v2 (M4-01): Progress.PendingEpithet, SaveSchema.Migrations[2].
	-- v3 (M3B-01/M3B-05): Meta.Unlocks.Combat, Character.LivesLeft,
	-- SaveSchema.Migrations[3].
	-- v4 (M5C-01): Progress.DeliveryStreak, Progress.Routes,
	-- SaveSchema.Migrations[4].
	SchemaVersion = 4,
}

-- M1-05: SYSTEMS.md section 16's UserId, kept as the one source of truth.
-- A player also counts as a dev when Config.Debug.Enabled (Studio) is true;
-- see DevService.IsDev.
Config.Dev = {
	Admins = { 27938432 },
}

-- M2-02: aging (DESIGN.md section 3, "Aging while offline"/"Aging and
-- death"). AgeService multiplies the online tick's banked seconds by
-- DevService.GetTimeScale() (a runtime override of Config.Debug.TimeScale,
-- since Config is frozen); offline aging is always real time, never
-- scaled. SceneTimeout is real time too (REVIEW-M2-02 R7): the client's
-- scene takes about the same wall-clock time to play regardless of aging
-- speed, so scaling it down at a high timescale used to cut it off mid-play.
Config.Aging = {
	SecondsPerYear = if Config.IsStudio then 60 else 1800,
	OfflineYearsPerDay = 2,
	OfflineAgeCap = 59,
	AdultAge = 18,
	-- Hair visibly greys from GreyStart to GreyEnd (CharacterService.applyHairColor).
	GreyStart = 45,
	GreyEnd = 70,
	-- From DeathStart, every online birthday carries a heart-attack moment;
	-- DeathChance is the odds it's fatal, linearly interpolated between points.
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
	-- How often the online aging loop ticks, in real seconds.
	Tick = 10,
}

-- M3B-05 (Bryan, 2026-09-28): a character ("a life") gets this many lives
-- before a real death (Humanoid.Died - falling, the void, drowning, later
-- executions; a combat knockout never touches this) wipes to a brand-new
-- character. See Character.LivesLeft, SaveSchema.luau, LifeService.luau.
Config.Life = {
	LivesPerCharacter = 4,
	-- REVIEW-M3B-05 M1: how long a death with lives left waits before
	-- respawning the same character - long enough to read as a real death
	-- moment, short enough not to feel like a hang (Players.RespawnTime,
	-- the engine's own default, is left alone).
	RespawnDelay = 3,
}

-- M2-03: max health and block (DESIGN.md section 3a "Rank raises max
-- health", TRIAGE #14). Numbers kept from the old scripts where they
-- weren't broken; see HealthService's own comments for what changed.
Config.Health = {
	Base = 50, -- old StarterHealth
	HeightBonus = 3, -- per Height ratio unit; same multiplier the old Race==2 formula used
	-- Indexed by Ranks.rankFor's rank index (1 = Street Rat .. 7 = King/Queen).
	RankBonus = { 0, 10, 20, 35, 50, 70, 100 },
	RegenPerSecond = { Idle = 2, Combat = 0, Knocked = 1 },
	MaxBlock = 100,
	BlockRegenPerSecond = 10,
	-- How often the shared regen loop ticks, in real seconds.
	Tick = 1,
	-- M3-03 (REVIEW-M3-03 M2): CombatService.SetTier(player, "Combat") on
	-- any hit dealt or taken; it falls back to "Idle" once this many
	-- seconds pass with no further combat activity (and no longer than
	-- that - "Knocked" always wins over both while it's active).
	CombatTierSeconds = 6,
}

-- M3-FIX3-S/M3-FIX3-C/M3-FIX4: the animation-driven, per-style hit chain
-- (Shared/Data/Combat.luau's Combat.Styles shape). Not weapon numbers -
-- those stay in Combat.luau. One click plays one swing animation for the
-- attacker's WeaponSet style, containing several hits; the client reports
-- each hit off the animation's own events.
Config.Combat = {
	-- Seconds of slack added to BOTH ends of a hit's hitWindow when the
	-- server checks an AttackHit report (and to AttackCancel's cancelWindow/
	-- cancelUntil), absorbing network round-trip and animation-marker
	-- jitter between the client's animation clock and the server's own.
	HitTolerance = 0.15,
	-- The real marker names can't be read from the .rbxm file, so this is a
	-- starting guess - Bryan edits it to match each style's actual animation
	-- event names, one Windup/Hit name per hit in the chain, in order. With
	-- LogMarkers on (the default), CombatController logs every
	-- KeyframeReached AND every configured marker that's actually reached
	-- on whichever style's track is playing (`Log:Info("marker: <name> at
	-- <t>s")`), so the real names and their timing show up in Output even
	-- before the guess is right.
	Markers = {
		Fist = {
			Windup = { "Windup1", "Windup2" },
			Hit = { "Hit1", "Hit2" },
		},
		Dagger = {
			Windup = { "Windup1", "Windup2", "Windup3" },
			Hit = { "Hit1", "Hit2", "Hit3" },
		},
	},
	LogMarkers = true,
	-- How long EffectsController flashes the "Cancel" Highlight for a
	-- cancelled (not interrupted) attack.
	CancelFlashSeconds = 0.25,
	-- M3-FIX3-C (client): fallback wind-up slowdown (1 = normal speed, less
	-- = slower) for a hit whose own windupSpeed isn't available from
	-- Shared/Data/Combat.luau's Combat.Styles yet (M3-FIX4-S, in progress
	-- in parallel) - once that lands, CombatController prefers each hit's
	-- own windupSpeed (Lights 1.0, Heavies slowed) and only falls back to
	-- this flat number if that data is missing. A pure client feel knob -
	-- the server never reads this, it only ever validates hitWindow/
	-- cancelUntil, so retuning this doesn't need to match any server timing.
	WindupSpeed = 0.5,
	-- M3B-01/M3B-03: the combat stance (docs/M3B-PLAN.md section 1). The
	-- key toggles SetStance(not InCombat); clicks/Block/cancel only work
	-- while InCombat (a click with a weapon Tool equipped is the one
	-- exception -- it enters the stance first). Bryan can rebind the key
	-- freely.
	StanceKey = Enum.KeyCode.C,
	-- One looping idle animation id per style, played on any character
	-- while InCombat (own and others) so everyone can see who's ready to
	-- fight; empty = no animation for that style yet. Bryan fills these in.
	StanceAnimations = {
		Fist = "",
		Dagger = "",
	},
	-- Matches the server's default (docs/M3B-PLAN.md section 2) only in
	-- spirit -- the server's CombatUnlocked attribute is the real source
	-- of truth; this client never decides unlock state itself, it only
	-- reads that attribute. Until the tutorial (a later milestone) exists,
	-- every new life starts unlocked - once earned for real, it's for every
	-- future character too (Meta.Unlocks.Combat survives DataService.
	-- NewLife; only Wipe clears it).
	UnlockedByDefault = true,
	-- How long the "you don't know how to fight yet" line stays up.
	LockedMessageSeconds = 2,
}

-- M2-05: the heart-attack/death scene's sound. Bryan: swap for your own sound.
Config.Sfx = {
	Heartbeat = "rbxassetid://102383912898742",
}

-- M2-FIX-C (BUG-16): every timing for the heart-attack pulses and the
-- return-to-the-Rukh scene, so Bryan can tune the pacing directly. The
-- scene's look (colours, the AfterLife model itself) stays in
-- RukhController and his own ReplicatedFirst.AfterLife model, not here.
Config.Scene = {
	-- A heartbeat is "lub-dub": two quick beats. BeatGap is the gap
	-- between them; PairGap is the pause after the pair before the next
	-- cycle (seconds).
	BeatGap = 0.25,
	PairGap = 0.8,
	-- Heart-attack moment length, in lub-dub cycles.
	NonFatalCycles = 2,
	FatalCycles = 3,
	-- Each fatal cycle's BeatGap/PairGap is multiplied by this again
	-- (compounding), so the beats slow and the pauses grow cycle to
	-- cycle, per Bryan's "too fast" note.
	FatalSlowFactor = 1.4,
	-- How long "Your heart gave out." stays up before the scene starts.
	MessageSeconds = 2,
	-- The return-to-the-Rukh walk: total time, and how much of the end
	-- of it is the fade to white.
	WalkSeconds = 6,
	FadeSeconds = 2,
	-- How far ahead of the spawn point the stand-in core sits when
	-- Bryan's AfterLife model has no AfterlifeCore of its own (studs).
	CoreDistance = 15,
}

-- M3-04: NpcService/AiController (TRIAGE #20). NPCs are combatants exactly
-- like players (Bryan, 2026-09-27): MaxHealth comes from here, by
-- NpcType, instead of the player rank ladder.
Config.Npc = {
	-- How often the shared AiController loop ticks every NPC's tree.
	TickSeconds = 0.2,
	ChaseRadius = 30,
	GiveUpRadius = 40,
	AttackRange = 4,
	AttackCooldown = 1.4,
	WanderRadius = 12,
	MaxHealth = { Dummy = 100, Target = 100 },
	-- REVIEW-M3-04 L2: optional asset ids Bryan can fill in for the walk/
	-- run/flinch animations (empty by default - Trees.luau's by-name
	-- Animation-instance lookup on the model itself is tried first; this
	-- is only a fallback for when the art doesn't have one).
	Animations = { Walk = "", Run = "", Flinch = "" },
	-- M3B-02: the seven training dummies (docs/M3B-PLAN.md section 3,
	-- Bryan's roster, approved 2026-09-28). All Fist style. reactionSeconds
	-- is the delay before a dummy reacts to something it read off the
	-- player's own attributes (CurrentHit/Attacking); rhythmSeconds paces a
	-- dummy that throws on its own schedule rather than reacting; weights
	-- are Sparring Sinbad's own throw/cancel/parry/dash mix. engageRadius
	-- (12): a trainer only fights its spawner or the nearest player within
	-- this many studs - PLACEHOLDERS, Bryan retunes every number here once
	-- he's felt each dummy against the real animations.
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
	-- The teaching order (docs/M3B-PLAN.md section 3's own table) - also
	-- `.dummy list`'s print order, since Lua tables don't keep one.
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

-- M5C-01: delivery missions (M5-PLAN.md Phase 5C, Bryan's rules 2026-09-29).
-- OpenStuds/BoardCloseStuds give the board some hysteresis (open close to
-- the part, close only once well clear of it, so standing right at the
-- part's edge doesn't flicker); ArriveStuds is the same idea for the
-- destination part. PlayerActiveThreshold/SafeRouteThreshold are the old
-- MissionHandler's own numbers (AUDIT M12's fix wires them to something
-- real: the player's own Progress.Routes count and each city's static
-- Safety value, instead of a global counter nothing ever updated).
Config.Missions = {
	OpenStuds = 12,
	BoardCloseStuds = 20,
	ArriveStuds = 10,
	PlayerActiveThreshold = 10,
	SafeRouteThreshold = 0.75,
	TimeCrunchSeconds = 180,
	-- REVIEW-M5C-01 M2 (lead decision, Bryan may change it): an interception
	-- only pays if the courier is genuinely out on the route - at least this
	-- far from where they started, or this far into the run - so two
	-- accounts can't farm the reward by knocking a courier out right next
	-- to the board they just opened.
	InterceptMinStuds = 100,
	InterceptMinSeconds = 30,
	-- The intercepted mark (Bryan): every interception adds one stack to the
	-- courier (Progress.Intercepted); MissionService.OfferMultiplier =
	-- max(InterceptedFloor, InterceptedDecay ^ stacks) multiplies that
	-- player's own board offers, their own reduced payout if they still
	-- complete a marked delivery, and an interceptor's own payout while the
	-- victim is marked (no Black Rukh either, while marked) - one completed
	-- delivery clears every stack, after paying it at the reduced rate.
	InterceptedDecay = 0.5,
	InterceptedFloor = 0.1,
	HeavyCargoSpeedMult = 0.75,
	MagoiPerDelivery = 10,
	-- How often the shared board/run loop ticks (arrival checks, TimeCrunch
	-- expiry, the beacon) - not a per-frame loop (AUDIT H9).
	Tick = 0.5,
	-- Courier beacon (Bryan, 2026-09-29): a Highlight visible through walls,
	-- same look as the old MissionHandler:316 (DepthMode = AlwaysOnTop) -
	-- the client draws it off the CourierBeacon character attribute this
	-- toggles. The old code had no real equivalent timing to port (its only
	-- similar effect, HighlyValuable's package sparkle at MissionHandler:
	-- 311-328, cycles on its own unrelated 1s-fade/6s-hold/20s-off tween for
	-- a different purpose) - these are Bryan's own approved numbers.
	Beacon = {
		everySeconds = 30,
		forSeconds = 3,
	},
}

-- M4-02: the Rukh flutter on RankUp/AlignmentChanged (DESIGN.md section 3a).
-- Emitters are exactly the ParticleEmitter names under
-- ReplicatedFirst.VFX.RukhEffects; Bryan can rename, add or remap any of
-- these lists freely without touching RankController. EmitRate multiplies
-- every cloned emitter's own Rate (1 = whatever Bryan authored in Studio).
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
table.freeze(Config.Combat.StanceAnimations)
table.freeze(Config.Combat)
table.freeze(Config.Sfx)
table.freeze(Config.Scene)
table.freeze(Config.Npc.MaxHealth)
table.freeze(Config.Npc.Animations)
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
table.freeze(Config.Missions)

-- M6 (docs/M6-PLAN.md, Bryan approved 2026-09-29): the world. Music, the
-- shared day clock, the ocean and footsteps. The night look itself lives in
-- Shared/Data/DayNight.luau, the region playlists in Shared/Data/Regions.luau.
Config.World = {
	Music = {
		-- One volume for every playlist track (Bryan: the old code mixed 0.05
		-- and 0.5 and felt finicky). Ambient loops keep their own volume in
		-- Regions.luau.
		Volume = 0.5,
		CrossfadeSeconds = 1,
		-- How often the client tests its position against the region boxes.
		RegionPollSeconds = 0.25,
	},
	DayNight = {
		-- The old game's Day/Night Cycle script: 10 real minutes of daylight
		-- (06:00 to 18:00) and 6 of night. Day must stay longer than night
		-- (Bryan). Total = one in-game day.
		DaySeconds = 600,
		NightSeconds = 360,
		DawnHour = 6,
		DuskHour = 18,
		-- How long the palette blends at dawn and dusk, and how long a tagged
		-- city light takes to fade on or off (seconds).
		TransitionSeconds = 60,
		LightFadeSeconds = 2,
		-- The CollectionService tag Bryan puts on a lamp, torch or fire part
		-- or model: its lights, fires and particles run at night only, and a
		-- Neon part in it swaps to this material by day.
		Tag = "CityLight",
		DayMaterial = Enum.Material.SmoothPlastic,
	},
	Ocean = {
		-- Off until Bryan deletes the 766 old wave scripts under
		-- Workspace.MAP.OCEAN (docs/TINKER.md), which would otherwise fight
		-- the client for the tile positions.
		Enabled = false,
		-- The old scripts' timing: tiles rise 2 studs over 15 s, hold 3 s,
		-- fall 15 s; wave decals fade in over 10 s, out over 10 s, pause 10 s.
		Amplitude = 2,
		RiseSeconds = 15,
		HoldSeconds = 3,
		DecalFadeSeconds = 10,
		DecalPauseSeconds = 10,
		DecalVisibleTransparency = 0.95,
		-- Tiles farther than this from the camera are left still (studs).
		CullDistance = 6000,
	},
	Footsteps = {
		WalkVolume = 0.3,
		RunVolume = 0.5,
		-- Sand and mud prints: how long one stays and how far below the
		-- torso the raycast looks for the ground (studs).
		PrintSeconds = 8,
		PrintRayStuds = 6,
	},
}
table.freeze(Config.World.Music)
table.freeze(Config.World.DayNight)
table.freeze(Config.World.Ocean)
table.freeze(Config.World.Footsteps)
table.freeze(Config.World)
table.freeze(Config)

return Config
