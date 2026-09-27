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
	SchemaVersion = 1,
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
table.freeze(Config.Health.RankBonus)
table.freeze(Config.Health.RegenPerSecond)
table.freeze(Config.Health)
table.freeze(Config.Sfx)
table.freeze(Config.Scene)
table.freeze(Config.Npc.MaxHealth)
table.freeze(Config.Npc.Animations)
table.freeze(Config.Npc)
table.freeze(Config)

return Config
