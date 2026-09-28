--!strict
-- Runs quick, in-process checks of the shared core (Validate + the remote
-- wrapper) at Start, only when Config.Debug.Enabled. Never throws; logs one
-- PASS/FAIL summary line.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local Validate = require(ReplicatedStorage.Shared.Validate)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local SaveSchema = require(ReplicatedStorage.Shared.SaveSchema)
local DataService = require(script.Parent.DataService)
local PlayerService = require(script.Parent.PlayerService)
local DevService = require(script.Parent.DevService)
local Ranks = require(ReplicatedStorage.Shared.Data.Ranks)
local Alignment = require(ReplicatedStorage.Shared.Data.Alignment)
local Epithets = require(ReplicatedStorage.Shared.Data.Epithets)
local CharacterService = require(script.Parent.CharacterService)
local AgeService = require(script.Parent.AgeService)
local LifeService = require(script.Parent.LifeService)
local AgeHandler = require(script.Parent.AgeService.AgeHandler)
local HealthService = require(script.Parent.HealthService)
local RankService = require(script.Parent.RankService)
local Economy = require(ReplicatedStorage.Shared.Data.Economy)
local EconomyService = require(script.Parent.EconomyService)
local Shop = require(ReplicatedStorage.Shared.Data.Shop)
local ItemService = require(script.Parent.ItemService)
local ShopService = require(script.Parent.ShopService)
local StatusService = require(script.Parent.StatusService)
local MovementService = require(script.Parent.MovementService)
local CombatService = require(script.Parent.CombatService)
local BehaviorTree = require(ReplicatedStorage.Shared.BehaviorTree)
local NpcService = require(script.Parent.NpcService)
local NpcTrees = require(script.Parent.NpcService.Trees)
local Combat = require(ReplicatedStorage.Shared.Data.Combat)
local Cities = require(ReplicatedStorage.Shared.Data.Cities)
local MissionService = require(script.Parent.MissionService)
local WorldClockService = require(script.Parent.WorldClockService)
local CollisionService = require(script.Parent.CollisionService)
local Assets = require(ReplicatedFirst.Assets) :: any

local log = Log.new("SelfTest")

type Check = { name: string, pass: boolean }
type RemoteDef = Remotes.RemoteDef

local function expect(results: { Check }, name: string, condition: boolean)
	table.insert(results, { name = name, pass = condition })
end

-- BUG-26 (M3-FIX2-S): polls `predicate` instead of asserting right after a
-- fixed `task.wait(n)` - Studio runs with Deferred signal behavior (a
-- BindableEvent connection doesn't run until the firing thread's next
-- resumption point, not synchronously) and task.wait can genuinely take
-- longer than requested under load, so no fixed wait is ever provably
-- enough. Returns true as soon as `predicate()` does, otherwise keeps
-- yielding (never busy-loops without a wait) until `timeoutSeconds` have
-- passed, then makes one final check.
local function pollUntil(timeoutSeconds: number, predicate: () -> boolean): boolean
	local deadline = os.clock() + timeoutSeconds
	while os.clock() < deadline do
		if predicate() then
			return true
		end
		task.wait()
	end
	return predicate()
end

local function testValidators(results: { Check })
	local number = Validate.number({ min = 0, max = 10, integer = true })
	expect(results, "number: good value accepted", (number(5)))
	expect(results, "number: NaN rejected", not (number(0 / 0)))
	expect(results, "number: +inf rejected", not (number(math.huge)))
	expect(results, "number: -inf rejected", not (number(-math.huge)))
	expect(results, "number: wrong type rejected", not (number("5")))
	expect(results, "number: out of range rejected", not (number(11)))
	expect(results, "number: non-integer rejected", not (number(1.5)))

	local str = Validate.string({ maxLen = 5 })
	expect(results, "string: good value accepted", (str("abc")))
	expect(results, "string: too long rejected", not (str("abcdef")))
	expect(results, "string: wrong type rejected", not (str(123)))

	local oneOf = Validate.string({ maxLen = 10, oneOf = { "a", "b" } })
	expect(results, "string: oneOf good value accepted", (oneOf("a")))
	expect(results, "string: oneOf rejects unlisted value", not (oneOf("c")))

	local bool = Validate.boolean()
	expect(results, "boolean: good value accepted", (bool(true)))
	expect(results, "boolean: wrong type rejected", not (bool(1)))

	local vec = Validate.vector3({ maxMagnitude = 10 })
	expect(results, "vector3: good value accepted", (vec(Vector3.new(1, 1, 1))))
	expect(results, "vector3: wrong type rejected", not (vec("nope")))
	expect(results, "vector3: too large rejected", not (vec(Vector3.new(100, 100, 100))))
	expect(results, "vector3: non-finite component rejected", not (vec(Vector3.new(0 / 0, 0, 0))))

	local inst = Validate.instance("BasePart")
	local part = Instance.new("Part")
	expect(results, "instance: good value accepted", (inst(part)))
	expect(results, "instance: wrong class rejected", not (inst(Instance.new("Folder"))))
	part:Destroy()

	local optionalNumber = Validate.optional(Validate.number())
	expect(results, "optional: nil accepted", (optionalNumber(nil)))
	expect(results, "optional: bad value still rejected", not (optionalNumber("x")))

	local direction = Validate.enum({ "north", "south" })
	expect(results, "enum: good value accepted", (direction("north")))
	expect(results, "enum: value outside list rejected", not (direction("east")))
end

local function testRemoteWrapper(results: { Check })
	-- No real player is needed: CheckCall only uses it as a rate-limit key.
	-- Each scenario gets its own fake player so their rate windows don't
	-- interfere with each other; every one is cleared at the end (a fake
	-- player never fires PlayerRemoving, so nothing else will clear it).
	local fakePlayers: { Player } = {}
	local function newFakePlayer(): Player
		local player = ({} :: any) :: Player
		table.insert(fakePlayers, player)
		return player
	end

	do
		local player = newFakePlayer()
		local ok = Remotes.Server.CheckCall("DebugPing", player, table.pack("hello"))
		expect(results, "remote: good DebugPing call accepted", ok)

		local okWrongType = Remotes.Server.CheckCall("DebugPing", player, table.pack(123))
		expect(results, "remote: wrong-type DebugPing call rejected", not okWrongType)

		local okTooLong = Remotes.Server.CheckCall("DebugPing", player, table.pack(string.rep("x", 51)))
		expect(results, "remote: over-length DebugPing call rejected", not okTooLong)

		local okUnknown = Remotes.Server.CheckCall("NotARealRemote", player, { n = 0 })
		expect(results, "remote: unknown remote name rejected", not okUnknown)
	end

	-- DebugPing allows 5 calls per second.
	do
		local player = newFakePlayer()
		local withinLimit = true
		for _ = 1, 5 do
			local passed = Remotes.Server.CheckCall("DebugPing", player, table.pack("x"))
			withinLimit = withinLimit and passed
		end
		expect(results, "remote: calls within rate limit accepted", withinLimit)

		local overLimit = Remotes.Server.CheckCall("DebugPing", player, table.pack("x"))
		expect(results, "remote: call over rate limit rejected", not overLimit)
	end

	-- H2: bad calls must still count against the rate limit, otherwise an
	-- attacker floods the server for free by never sending a valid call.
	do
		local player = newFakePlayer()
		local allRejectedForType = true
		for _ = 1, 5 do
			local ok, reason = Remotes.Server.CheckCall("DebugPing", player, table.pack(123))
			allRejectedForType = allRejectedForType and not ok and reason ~= "rate limit exceeded"
		end
		expect(results, "remote (H2): bad calls rejected for their own reason", allRejectedForType)

		local ok, reason = Remotes.Server.CheckCall("DebugPing", player, table.pack("valid"))
		expect(results, "remote (H2): rate limit still trips after only bad calls", not ok and reason == "rate limit exceeded")
	end

	-- M1: argument counting must use table.pack's .n, not #args, so a nil
	-- hole or an omitted trailing optional argument is handled correctly.
	do
		local def: RemoteDef = {
			kind = "Event",
			args = { Validate.string({ maxLen = 10 }), Validate.optional(Validate.number()) },
			rate = { count = 100, per = 1 },
		}

		local nilHoleInSecondArg = table.pack("a", nil)
		expect(
			results,
			"argcount (M1): nil-hole trailing optional accepted",
			(Remotes.Server.ValidateArgsForTest(def, nilHoleInSecondArg))
		)

		local omittedTrailingOptional = table.pack("a")
		expect(
			results,
			"argcount (M1): omitted trailing optional accepted",
			(Remotes.Server.ValidateArgsForTest(def, omittedTrailingOptional))
		)

		local tooManyArgs = table.pack("a", 1, "extra")
		expect(
			results,
			"argcount (M1): extra argument rejected",
			not (Remotes.Server.ValidateArgsForTest(def, tooManyArgs))
		)
	end

	-- BUG-25/BUG-04 (M3-FIX-S): confirms Validate.number's NaN rejection
	-- actually reaches a real remote through the full CheckCall wrapper
	-- (not just Validate.number in isolation, already self-tested
	-- elsewhere) - the reported "no warning" turned out to be BUG-04's
	-- per-window throttle hiding a real drop, not a validation gap.
	do
		local player = newFakePlayer()
		local okNaN, reasonNaN = Remotes.Server.CheckCall("Dash", player, table.pack(0 / 0, 1))
		expect(results, "remote: Dash(NaN, 1) is rejected through the wrapper (BUG-25)", not okNaN and reasonNaN ~= nil)
	end

	for _, player in fakePlayers do
		Remotes.Server.ClearPlayerState(player)
	end
end

-- M1-03: a fake Data table exercises SaveSchema.Migrate's version bump, and
-- a temporary Folder stands in for a Player.
local function testDataService(results: { Check })
	do
		local data = ({ Version = 0 } :: any) :: SaveSchema.Data
		SaveSchema.Migrate(data)
		expect(results, "SaveSchema: Migrate bumps Version to the current schema version", data.Version == Config.Data.SchemaVersion)
	end

	-- M4-01: schema v2 only adds Progress.PendingEpithet, an optional field
	-- a v1 save (missing the key entirely) already reads the same as nil.
	do
		local data = ({
			Version = 1,
			Progress = { Magoi = 0, GoldRukh = 0, BlackRukh = 0, Epithet = "" },
		} :: any) :: SaveSchema.Data
		SaveSchema.Migrate(data)
		expect(results, "SaveSchema: v1 -> v2 migration bumps Version to 2", data.Version == 2)
		expect(results, "SaveSchema: v1 -> v2 migration leaves PendingEpithet nil (nothing to fill)", data.Progress.PendingEpithet == nil)
	end

	-- M3B-01: schema v3 adds Meta.Unlocks.Combat. The fake input already has
	-- Unlocks pre-populated (simulating what Profile:Reconcile() would have
	-- already backfilled in production, before Migrate ever runs - same
	-- reasoning as Migrations[3]'s own comment).
	do
		local data = ({
			Version = 2,
			Meta = { Created = 0, LastSeen = 0, Lives = 1, Unlocks = { Combat = false } },
		} :: any) :: SaveSchema.Data
		SaveSchema.Migrate(data)
		expect(results, "SaveSchema: v2 -> v3 migration bumps Version to 3", data.Version == 3)
		expect(results, "SaveSchema: v2 -> v3 migration sets Meta.Unlocks.Combat = true (grandfathered - nobody loses combat)", data.Meta.Unlocks.Combat == true)
	end

	-- M5C-01: schema v4 adds Progress.DeliveryStreak, Progress.Routes and
	-- (the intercepted mark, added later while still unmerged) Progress.
	-- Intercepted - an intentional no-op migration (same reasoning as
	-- v1 -> v2 above - all three new fields already read the same as their
	-- template default before Migrate ever runs).
	do
		local data = ({
			Version = 3,
			Progress = { Magoi = 0, GoldRukh = 0, BlackRukh = 0, Epithet = "", DeliveryStreak = 0, Routes = {}, Intercepted = 0 },
		} :: any) :: SaveSchema.Data
		SaveSchema.Migrate(data)
		expect(results, "SaveSchema: v3 -> v4 migration bumps Version to 4", data.Version == 4)
		expect(
			results,
			"SaveSchema: v3 -> v4 migration leaves DeliveryStreak/Routes/Intercepted at their already-backfilled defaults",
			data.Progress.DeliveryStreak == 0 and next(data.Progress.Routes) == nil and data.Progress.Intercepted == 0
		)
	end

	do
		expect(results, "SaveSchema: a fresh template starts Meta.Unlocks.Combat false (earned, not automatic)", SaveSchema.Template.Meta.Unlocks.Combat == false)
		local wouldBeUnlocked = SaveSchema.Template.Meta.Unlocks.Combat or Config.Combat.UnlockedByDefault
		expect(
			results,
			"CombatService: CombatUnlocked follows Config.Combat.UnlockedByDefault for a fresh save (blanket-unlocked until the tutorial ships)",
			wouldBeUnlocked == Config.Combat.UnlockedByDefault
		)
	end

	-- REVIEW-M3B-01 C1: a brand-new profile follows exactly this path
	-- (ProfileStore's own deep copy of SaveSchema.Template, then
	-- Profile:Reconcile(), then SaveSchema.Migrate - DataService.luau's
	-- onPlayerAdded). Migrate must be a no-op for it now that the
	-- template's own Version is already current - before the fix, this
	-- walked a fresh profile through Migrations[3] too, which grandfathered
	-- it into Meta.Unlocks.Combat = true even though nothing was ever
	-- "existing" to grandfather.
	do
		local function deepCopy(value: any): any
			if type(value) ~= "table" then
				return value
			end
			local copy = {}
			for key, inner in value do
				copy[key] = deepCopy(inner)
			end
			return copy
		end

		local data = deepCopy(SaveSchema.Template) :: SaveSchema.Data
		SaveSchema.Migrate(data)
		expect(results, "SaveSchema: migrating a fresh deep copy of the template is a no-op (Version is already current)", data.Version == Config.Data.SchemaVersion)
		expect(results, "SaveSchema: a brand-new profile starts with Meta.Unlocks.Combat false (earned, not automatic)", data.Meta.Unlocks.Combat == false)
		expect(results, "SaveSchema: a brand-new profile starts with a full Character.LivesLeft", data.Character.LivesLeft == Config.Life.LivesPerCharacter)
	end

	-- M3B-01 (Bryan's refinement, 2026-09-28): the combat unlock is
	-- per-player forever, not per-life - DataService.ResetToTemplate is the
	-- exact reset both Wipe and NewLife build on, so exercising it directly
	-- proves what each of them actually does to Meta.Unlocks.Combat, with no
	-- Player/ProfileStore involved.
	do
		local data = ({
			Version = Config.Data.SchemaVersion,
			Character = { LivesLeft = 0 },
			Meta = { Created = 111, LastSeen = 0, Lives = 3, Unlocks = { Combat = true } },
		} :: any) :: SaveSchema.Data
		local keepCombatUnlocked = data.Meta.Unlocks.Combat

		DataService.ResetToTemplate(data)
		data.Meta.Unlocks.Combat = keepCombatUnlocked -- NewLife's own restore step

		expect(results, "DataService: NewLife's reset carries Meta.Unlocks.Combat over (per-player forever, not per-life)", data.Meta.Unlocks.Combat == true)
		-- M3B-05: a brand-new character always starts with a full life count,
		-- regardless of how many the character it replaces had left (0 here).
		expect(results, "DataService: NewLife's reset gives the new character a full Character.LivesLeft again", data.Character.LivesLeft == Config.Life.LivesPerCharacter)
	end

	do
		local data = ({
			Version = Config.Data.SchemaVersion,
			Meta = { Created = 111, LastSeen = 0, Lives = 3, Unlocks = { Combat = true } },
		} :: any) :: SaveSchema.Data

		DataService.ResetToTemplate(data)

		expect(results, "DataService: Wipe's reset (no restore step) clears Meta.Unlocks.Combat back to the template's false", data.Meta.Unlocks.Combat == false)
	end

	-- REVIEW-M5C-01B F1: DataService.RunReleasing must run every registered
	-- OnReleasing handler BEFORE `endSession` - profile:EndSession() fires
	-- ProfileStore's own OnSessionEnd synchronously, which nils
	-- `profiles[player]` before onPlayerRemoving even returns, so a plain
	-- Players.PlayerRemoving connection made by another service (however
	-- early) can never see the save before it's released. This is the
	-- mechanism M5C-01's "leaving mid-run" fix relies on - see
	-- MissionService's own DataService.OnReleasing registration, and
	-- TrySettle/ApplyFailure below for the actual "zeroes the streak" math
	-- this now runs in time for.
	do
		local order: { string } = {}
		DataService.OnReleasing(function()
			table.insert(order, "handler")
		end)
		local standIn = Instance.new("Folder")
		local fakePlayer = (standIn :: any) :: Player
		DataService.RunReleasing(fakePlayer, function()
			table.insert(order, "released")
		end)
		expect(
			results,
			"DataService: RunReleasing runs every OnReleasing handler before the release itself (REVIEW-M5C-01B F1)",
			#order == 2 and order[1] == "handler" and order[2] == "released"
		)
		standIn:Destroy()
	end

	-- REVIEW-M5C-01C L1: a single misbehaving OnReleasing handler must not
	-- block the release - RunReleasing pcalls each handler individually, so
	-- one that errors still lets every later handler run AND still lets
	-- endSession run.
	do
		local ranAfterError = false
		local released = false
		DataService.OnReleasing(function()
			error("REVIEW-M5C-01C L1: deliberate self-test error")
		end)
		DataService.OnReleasing(function()
			ranAfterError = true
		end)
		local standIn = Instance.new("Folder")
		local fakePlayer = (standIn :: any) :: Player
		DataService.RunReleasing(fakePlayer, function()
			released = true
		end)
		expect(
			results,
			"DataService: RunReleasing still runs handlers registered after one that errors (REVIEW-M5C-01C L1)",
			ranAfterError
		)
		expect(
			results,
			"DataService: RunReleasing still runs endSession even when an OnReleasing handler errors (REVIEW-M5C-01C L1)",
			released
		)
		standIn:Destroy()
	end
end

-- M1-04S: the join state machine is pure (no Player needed), so every
-- transition is exercised directly.
local function testPlayerService(results: { Check })
	local NextJoinState = PlayerService.NextJoinState

	expect(results, "PlayerService: CharacterPlaced moves Loading to Loaded", NextJoinState("Loading", "CharacterPlaced") == "Loaded")
	expect(results, "PlayerService: ClientReady moves Loaded to Ready", NextJoinState("Loaded", "ClientReady") == "Ready")
	expect(
		results,
		"PlayerService: ClientReady is ignored while Loading",
		NextJoinState("Loading", "ClientReady") == "Loading"
	)
	expect(
		results,
		"PlayerService: CharacterPlaced does nothing once already Loaded",
		NextJoinState("Loaded", "CharacterPlaced") == "Loaded"
	)
	expect(
		results,
		"PlayerService: CharacterPlaced does nothing once Ready",
		NextJoinState("Ready", "CharacterPlaced") == "Ready"
	)
	expect(results, "PlayerService: Respawn resets Loaded back to Loading", NextJoinState("Loaded", "Respawn") == "Loading")
	expect(results, "PlayerService: Respawn resets Ready back to Loading", NextJoinState("Ready", "Respawn") == "Loading")
	expect(
		results,
		"PlayerService: full sequence Loading -> Loaded -> Ready",
		NextJoinState(NextJoinState("Loading", "CharacterPlaced"), "ClientReady") == "Ready"
	)
end

-- M1-05S: DevService.IsDev is always true in Studio (where self-tests run),
-- so the admin-list check is tested directly via IsAdminUserId instead.
-- Dispatch itself is exercised with a fake player table, the same trick
-- used by the Remotes self-test above.
local function testDevService(results: { Check })
	expect(results, "DevService: Bryan's UserId is an admin", DevService.IsAdminUserId(27938432))
	expect(results, "DevService: an unlisted UserId is not an admin", not DevService.IsAdminUserId(1))

	local fakePlayer = ({ Name = "SelfTestDev", UserId = 27938432 } :: any) :: Player

	local cmdReply = DevService.Dispatch(fakePlayer, ".cmd")
	expect(results, "DevService: .cmd from a dev returns the command list", cmdReply ~= nil and cmdReply:find("Dev commands:") ~= nil)

	local unknownReply = DevService.Dispatch(fakePlayer, ".notarealcommand")
	expect(
		results,
		"DevService: an unknown command still replies with help",
		unknownReply ~= nil and unknownReply:find("Unknown command") ~= nil
	)

	local notACommand = DevService.Dispatch(fakePlayer, "just chatting")
	expect(results, "DevService: a non-command chat line gets no reply", notACommand == nil)

	-- IsDev is always true in Studio (Config.Debug.Enabled short-circuits
	-- it), so a real non-dev Dispatch call can't happen here; stub IsDev
	-- itself for one assertion instead (REVIEW-M1-05S #1), then restore it
	-- so the checks above (and every other service) keep seeing the real
	-- permission check.
	local realIsDev = DevService.IsDev
	DevService.IsDev = function(_player: Player): boolean
		return false
	end
	local ok, nonDevReply = pcall(DevService.Dispatch, fakePlayer, ".cmd")
	DevService.IsDev = realIsDev
	expect(results, "DevService: Dispatch gives a non-dev no reply", ok and nonDevReply == nil)

	-- BUG-20: .mortal on|off flips the runtime flag, mirroring .timescale.
	local realMortal = DevService.IsMortal()
	DevService.Dispatch(fakePlayer, ".mortal on")
	expect(results, "DevService: .mortal on sets IsMortal true", DevService.IsMortal() == true)
	DevService.Dispatch(fakePlayer, ".mortal off")
	expect(results, "DevService: .mortal off sets IsMortal false", DevService.IsMortal() == false)
	local restoreCommand = if realMortal then ".mortal on" else ".mortal off"
	DevService.Dispatch(fakePlayer, restoreCommand)
end

-- M2-06: the shared rank/alignment/epithet data modules are pure, so
-- they're exercised directly without any Player or save table.
local function testData(results: { Check })
	do
		local _, streetRat = Ranks.rankFor(299)
		expect(results, "Ranks: 299 magoi is still Street Rat", streetRat == "Street Rat")

		local _, wanderer = Ranks.rankFor(300)
		expect(results, "Ranks: 300 magoi reaches Wanderer", wanderer == "Wanderer")

		local _, kingQueen = Ranks.rankFor(6000)
		expect(results, "Ranks: 6000 magoi reaches King/Queen", kingQueen == "King/Queen")

		expect(results, "Ranks: titleFor renders King for gender 1", Ranks.titleFor(6000, 1) == "King")
		expect(results, "Ranks: titleFor renders Queen for gender 2", Ranks.titleFor(6000, 2) == "Queen")
		expect(results, "Ranks: titleFor keeps King/Queen for gender 0", Ranks.titleFor(6000, 0) == "King/Queen")

		expect(results, "Ranks: nextThreshold after Street Rat is Wanderer's", Ranks.nextThreshold(0) == 300)
		expect(results, "Ranks: nextThreshold at the top is nil", Ranks.nextThreshold(6000) == nil)
	end

	do
		expect(results, "Alignment: 0/0 deeds is White (below MinDeeds)", Alignment.alignmentFor(0, 0) == "White")
		expect(results, "Alignment: 10/0 deeds is Gold", Alignment.alignmentFor(10, 0) == "Gold")
		expect(results, "Alignment: 3/7 deeds is Black", Alignment.alignmentFor(3, 7) == "Black")
		expect(results, "Alignment: 5/5 deeds is Gold & Black", Alignment.alignmentFor(5, 5) == "GoldBlack")
		expect(results, "Alignment: 2/1 deeds is White (below MinDeeds)", Alignment.alignmentFor(2, 1) == "White")
	end

	do
		local everyRank = { "Street Rat", "Wanderer", "Adventurer", "Renowned", "Hero", "Legend", "King/Queen" }
		local everyAlignment = { "White", "Gold", "Black", "GoldBlack" }
		local everyBankLargeEnough = true
		for _, rankTitle in everyRank do
			for _, alignment in everyAlignment do
				local bank = Epithets.bankFor(rankTitle, alignment :: Alignment.Alignment, 0)
				if #bank < 4 then
					everyBankLargeEnough = false
				end
			end
		end
		expect(results, "Epithets: every bank has at least 4 entries", everyBankLargeEnough)
	end

	do
		local picks = Epithets.pick3("Wanderer", "Gold", 0)
		expect(results, "Epithets: pick3 returns 3 entries", #picks == 3)
		expect(results, "Epithets: pick3 returns distinct entries", picks[1] ~= picks[2] and picks[1] ~= picks[3] and picks[2] ~= picks[3])
	end
end

-- M2-01: CharacterService's pure helpers, exercised with a fake save table
-- (no Player, no DataService, no Remotes involved).
local function fakeCharacterData(): SaveSchema.Data
	return {
		Version = 1,
		Character = {
			FirstName = "",
			Gender = 0,
			Race = 2,
			Kingdom = 1,
			SkinTone = 0,
			HairColor = { R = 0.5, G = 0.5, B = 0.5 },
			EyeColor = 1,
			FaceBase = 1,
			MouthShape = 1,
			Height = 10,
			GrowthProfile = "",
			LivesLeft = Config.Life.LivesPerCharacter,
		},
		Age = { Years = 13, TimePassed = 0, ProgToAge = 0 },
		Progress = { Magoi = 0, GoldRukh = 0, BlackRukh = 0, Epithet = "", DeliveryStreak = 0, Routes = {}, Intercepted = 0 },
		Bounty = 0,
		Economy = { Copper = 20, Silver = 0, Gold = 0 },
		Gear = { Shirt = "", Pants = "", Hats = { "", "", "" }, Inventory = {} },
		Family = {},
		Magic = {},
		Meta = { Created = 0, LastSeen = 0, Lives = 1, Unlocks = { Combat = false } },
	}
end

local function testCharacterService(results: { Check })
	do
		expect(results, "CharacterService: SkinTone 1 maps to Black", CharacterService.SkinTemplateName(1, 3) == "Black")
		expect(results, "CharacterService: SkinTone 2 maps to Brown", CharacterService.SkinTemplateName(2, 3) == "Brown")
		expect(results, "CharacterService: SkinTone 3 maps to White", CharacterService.SkinTemplateName(3, 3) == "White")
		expect(
			results,
			"CharacterService (P4): Kingdom 1 lightens White to LightTan",
			CharacterService.SkinTemplateName(3, 1) == "LightTan"
		)
		expect(
			results,
			"CharacterService (P4): Kingdom 2 lightens Black to Tan",
			CharacterService.SkinTemplateName(1, 2) == "Tan"
		)
		expect(
			results,
			"CharacterService (P4): Kingdom 2 lightens Brown to LightTan",
			CharacterService.SkinTemplateName(2, 2) == "LightTan"
		)
	end

	-- BUG-10: StatShim must expose every key RF/Assets reads via
	-- stat["X"].Value (it was missing HairColor, which crashed
	-- buildFalseHead and aborted the whole build). Exercised against the
	-- real Assets functions, not just a key-presence check, with two
	-- genders and both the human/magician EyeColor branches (L2).
	do
		local function checkShim(label: string, data: SaveSchema.Data)
			local stat = CharacterService.StatShim(data)
			for _, key in { "Gender", "FaceBase", "MouthShape", "EyeColor", "Race", "HairColor" } do
				expect(results, string.format("CharacterService StatShim (%s): has %s", label, key), stat[key] ~= nil and stat[key].Value ~= nil)
			end

			local ok, err = pcall(function()
				local faceBase = Assets.facebase(stat)
				faceBase:Destroy()
				local mouthShape = Assets.mouthshape(stat)
				mouthShape:Destroy()
				local eyeColor = Assets.eyecolor(stat)
				eyeColor:Destroy()
				local eyebrow = Assets.eyebrow(stat)
				eyebrow:Destroy()
			end)
			expect(results, string.format("CharacterService StatShim (%s): Assets functions don't error", label), ok)
			if not ok then
				log:Warn(string.format("StatShim (%s) self-test: %s", label, tostring(err)))
			end
		end

		local male = fakeCharacterData()
		male.Character.Gender = 1
		checkShim("male, human", male)

		local femaleMagician = fakeCharacterData()
		femaleMagician.Character.Gender = 2
		femaleMagician.Character.Race = 4
		checkShim("female, magician (L2)", femaleMagician)
	end

	do
		local data = fakeCharacterData()
		local applied = CharacterService.ApplyCreateCharacter(data, 1, 2)
		expect(results, "CharacterService: a good CreateCharacter call is applied", applied and data.Character.Gender == 1 and data.Character.SkinTone == 2)
		expect(results, "CharacterService: ApplyCreateCharacter rolls a FirstName", data.Character.FirstName ~= "")
	end

	do
		local data = fakeCharacterData()
		local rejected = CharacterService.ApplyCreateCharacter(data, 3, 1)
		expect(results, "CharacterService: an out-of-range gender is rejected", not rejected and data.Character.Gender == 0)
	end

	do
		local data = fakeCharacterData()
		local rejected = CharacterService.ApplyCreateCharacter(data, 1, 9)
		expect(results, "CharacterService: an out-of-range skin is rejected", not rejected and data.Character.SkinTone == 0)
	end

	do
		local data = fakeCharacterData()
		local first = CharacterService.ApplyCreateCharacter(data, 1, 1)
		local firstName = data.Character.FirstName
		local second = CharacterService.ApplyCreateCharacter(data, 2, 3)
		expect(
			results,
			"CharacterService: a second CreateCharacter call is ignored once Gender is set",
			first and not second and data.Character.Gender == 1 and data.Character.FirstName == firstName
		)
	end
end

-- M2-02: AgeService's pure helpers and AgeHandler's pack/unpack round-trip.
local function testAgeService(results: { Check })
	do
		expect(results, "AgeService: 10 days away at 13 -> 33", AgeService.OfflineAgingYears(13, 10) == 20)
		expect(results, "AgeService: 30 days away at 50 -> 59 (capped)", AgeService.OfflineAgingYears(50, 30) == 9)
		expect(results, "AgeService: 0 days away adds nothing", AgeService.OfflineAgingYears(13, 0) == 0)
	end

	do
		local chance = AgeService.DeathChance(62)
		expect(results, "AgeService: DeathChance interpolates 62 -> 0.07", math.abs(chance - 0.07) < 1e-9)
		expect(results, "AgeService: DeathChance below the first point clamps to it", AgeService.DeathChance(0) == Config.Aging.DeathChance[1][2])
		expect(
			results,
			"AgeService: DeathChance at/after the last point clamps to it",
			AgeService.DeathChance(200) == Config.Aging.DeathChance[#Config.Aging.DeathChance][2]
		)
	end

	do
		expect(results, "AgeService: GreyFactor(44) is 0 (before GreyStart)", AgeService.GreyFactor(44) == 0)
		expect(results, "AgeService: GreyFactor(57.5) is 0.5 (midpoint)", AgeService.GreyFactor(57.5) == 0.5)
		expect(results, "AgeService: GreyFactor(70) is 1 (at GreyEnd)", AgeService.GreyFactor(70) == 1)
	end

	do
		local profileStr, height = AgeHandler.start(13, 2, 1)
		local profile = AgeHandler.unpack(profileStr)
		expect(results, "AgeHandler: unpack succeeds on a freshly-packed profile", profile ~= nil)
		if profile then
			local roundTripHeight = AgeHandler.heightAt(profile, 13)
			expect(results, "AgeHandler: unpack round-trip reproduces the starting height", math.abs(roundTripHeight - height) < 0.01)
		end
		expect(results, "AgeHandler: unpack rejects a non-v1/garbage string", AgeHandler.unpack("garbage") == nil)
	end
end

-- M2-03: HealthService's pure helpers.
local function testHealthService(results: { Check })
	do
		expect(results, "HealthService: MaxHealthFor height 1.0 / rank 1", HealthService.MaxHealthFor(1.0, 1) == 53)
		expect(results, "HealthService: MaxHealthFor height 1.3 / rank 4", math.abs(HealthService.MaxHealthFor(1.3, 4) - 88.9) < 1e-9)
		-- REVIEW-M2-03 finding 1: the shared regen loop recomputes MaxHealth
		-- from the current height/rank every tick (not only at spawn), so a
		-- live AgeService birthday resize actually moves it. This confirms
		-- the formula it recomputes from really is height-sensitive at a
		-- fixed rank, same as a birthday would change under it.
		expect(
			results,
			"HealthService: MaxHealthFor tracks a live height change at a fixed rank",
			HealthService.MaxHealthFor(1.0, 1) ~= HealthService.MaxHealthFor(1.3, 1)
		)
	end

	do
		expect(results, "HealthService: RegenAmount Idle over 5s", HealthService.RegenAmount("Idle", 5) == 10)
		expect(results, "HealthService: RegenAmount Combat over 5s (no regen in combat)", HealthService.RegenAmount("Combat", 5) == 0)
		expect(results, "HealthService: RegenAmount Knocked over 5s", HealthService.RegenAmount("Knocked", 5) == 5)
	end

	-- REVIEW-M3-04 H1: an NPC registered with HealthService takes damage
	-- through TakeDamage (not a direct Humanoid.Health write) and is
	-- knocked at 0 exactly like a player - the identical CombatService.
	-- ApplyHit path, just with a Model instead of a Player behind it.
	do
		local scratch = Instance.new("Folder")
		scratch.Name = "SelfTestHealthServiceNpc"
		scratch.Parent = ServerStorage

		local attacker = Instance.new("Model")
		attacker.Parent = scratch
		local attackerHrp = Instance.new("Part")
		attackerHrp.Name = "HumanoidRootPart"
		attackerHrp.Anchored = true
		attackerHrp.Parent = attacker
		Instance.new("Humanoid").Parent = attacker

		local npc = Instance.new("Model")
		npc.Name = "SelfTestHealthServiceNpc"
		npc.Parent = scratch
		local npcHrp = Instance.new("Part")
		npcHrp.Name = "HumanoidRootPart"
		npcHrp.Anchored = true
		npcHrp.Parent = npc
		local npcHumanoid = Instance.new("Humanoid")
		npcHumanoid.Parent = npc

		HealthService.Register(npc, { maxHealth = 20 })
		expect(results, "HealthService: Register sets an NPC's MaxHealth/Health", npcHumanoid.MaxHealth == 20 and npcHumanoid.Health == 20)

		StatusService.Register(npc)
		CombatService.Register(attacker, nil, "Fist")
		CombatService.Register(npc, nil, "Fist")

		local fistStyle = Combat.styleFor("Fist") :: Combat.Style
		local hit = fistStyle.chain[1] -- 4 damage
		CombatService.ApplyHit(attacker, npc, fistStyle, hit, 1)
		expect(
			results,
			"HealthService: an NPC's non-lethal hit goes through TakeDamage",
			npcHumanoid.Health == 16 and npc:GetAttribute("Health") == 16
		)

		npcHumanoid.Health = 3 -- less than the next hit's damage
		CombatService.ApplyHit(attacker, npc, fistStyle, hit, 1)
		expect(
			results,
			"HealthService: a lethal hit still knocks an NPC out instead of killing it",
			npcHumanoid.Health == 1 and StatusService.Has(npc, "Knocked")
		)

		HealthService.Unregister(npc)
		StatusService.Unregister(npc)
		CombatService.Unregister(attacker)
		CombatService.Unregister(npc)
		scratch:Destroy()
	end
end

-- M4-01: RankService's pure helpers, exercised with fake Data tables - no
-- Player or DataService needed for any of these (ApplyMagoi/ApplyDeed/
-- ApplyChooseEpithet/ShouldOfferOrigin only ever touch data.Progress).
local function fakeRankData(magoi: number, gold: number, black: number, epithet: string): SaveSchema.Data
	return ({
		Progress = { Magoi = magoi, GoldRukh = gold, BlackRukh = black, Epithet = epithet, PendingEpithet = nil },
	} :: any) :: SaveSchema.Data
end

local function testRankService(results: { Check })
	do
		local data = fakeRankData(250, 0, 0, "")
		local oldIndex, newIndex = RankService.ApplyMagoi(data, 100) -- 250 -> 350: crosses the 300 Wanderer threshold
		expect(results, "RankService: ApplyMagoi detects a rank-up across a threshold", newIndex > oldIndex)
		expect(results, "RankService: ApplyMagoi actually moved Magoi", data.Progress.Magoi == 350)

		local sameOld, sameNew = RankService.ApplyMagoi(data, 10) -- 350 -> 360: still Wanderer
		expect(results, "RankService: ApplyMagoi doesn't report a rank-up within the same rank", sameNew == sameOld)

		local downOld, downNew = RankService.ApplyMagoi(data, -1000)
		expect(results, "RankService: ApplyMagoi clamps at 0", data.Progress.Magoi == 0)
		expect(results, "RankService: a rank DOWN is never reported as a rank-up", downNew <= downOld)
	end

	do
		local data = fakeRankData(0, 0, 0, "")
		local oldAlignment, newAlignment = RankService.ApplyDeed(data, "Gold", 10)
		expect(
			results,
			"RankService: ApplyDeed moves White to Gold once MinDeeds is cleared",
			oldAlignment == "White" and newAlignment == "Gold"
		)
	end

	do
		local choices = Epithets.pick3("Renowned", "Black", 0)
		expect(
			results,
			"RankService: pick3 returns 3 distinct entries for a real rank/alignment",
			#choices == 3 and choices[1] ~= choices[2] and choices[1] ~= choices[3] and choices[2] ~= choices[3]
		)
	end

	do
		local data = fakeRankData(300, 0, 0, "")
		local ok, reason = RankService.ApplyChooseEpithet(data, 1)
		expect(results, "RankService: ChooseEpithet rejects with nothing pending", not ok and reason ~= nil)

		data.Progress.PendingEpithet = { rank = 2, choices = { "A", "B", "C" } }
		local okBadIndex = RankService.ApplyChooseEpithet(data, 4)
		expect(results, "RankService: ChooseEpithet rejects an out-of-range index", not okBadIndex and data.Progress.Epithet == "")

		local okGood = RankService.ApplyChooseEpithet(data, 2)
		expect(
			results,
			"RankService: ChooseEpithet applies a valid choice and clears the pending one",
			okGood and data.Progress.Epithet == "B" and data.Progress.PendingEpithet == nil
		)
	end

	do
		local fresh = fakeRankData(0, 0, 0, "")
		expect(
			results,
			"RankService: a fresh template with Gender 0 isn't offered an origin choice yet",
			not RankService.ShouldOfferOrigin(fresh, 0)
		)
		expect(
			results,
			"RankService: a fresh template offers its origin choice once Gender is chosen",
			RankService.ShouldOfferOrigin(fresh, 1)
		)

		local pending = fakeRankData(0, 0, 0, "")
		pending.Progress.PendingEpithet = { rank = 1, choices = { "A", "B", "C" } }
		expect(results, "RankService: no origin offer while one is already pending", not RankService.ShouldOfferOrigin(pending, 1))

		local chosen = fakeRankData(0, 0, 0, "The Sand-Born")
		expect(results, "RankService: no origin offer once an epithet is already chosen", not RankService.ShouldOfferOrigin(chosen, 1))
	end

	do
		expect(results, "RankService: TitleForIndex resolves King/Queen for a known gender", RankService.TitleForIndex(7, 1) == "King")
	end

	-- H1 (REVIEW-M4-01): a rank-up must never overwrite a choice that's
	-- still pending, and a grant crossing several thresholds at once must
	-- walk the player through every rank one card at a time.
	do
		local data = fakeRankData(0, 0, 0, "")
		data.Progress.PendingEpithet = { rank = 1, choices = { "The Merchant's Child", "The Sand-Born", "The Unwanted" } }

		local oldIndex, newIndex = RankService.ApplyMagoi(data, 300) -- 0 -> 300: crosses into Wanderer
		expect(
			results,
			"RankService H1: Magoi crossing a threshold while origin is pending still reports a rank-up",
			newIndex > oldIndex
		)

		local announceIndex = RankService.NextRankToAnnounce(data, oldIndex, newIndex)
		expect(results, "RankService H1: a rank-up never overwrites a still-pending choice", announceIndex == nil)
		expect(
			results,
			"RankService H1: the pending choice itself is untouched (still the origin choices)",
			data.Progress.PendingEpithet ~= nil
				and data.Progress.PendingEpithet.rank == 1
				and data.Progress.PendingEpithet.choices[1] == "The Merchant's Child"
		)
	end

	do
		local data = fakeRankData(300, 0, 0, "") -- already at Wanderer's threshold
		data.Progress.PendingEpithet = { rank = 1, choices = { "The Merchant's Child", "The Sand-Born", "The Unwanted" } }

		local ok = RankService.ApplyChooseEpithet(data, 2) -- chooses "The Sand-Born"
		expect(results, "RankService H1: choosing the origin epithet succeeds", ok and data.Progress.Epithet == "The Sand-Born")

		local announceIndex = RankService.NextRankAfterChoice(data, 1)
		expect(
			results,
			"RankService H1: answering origin immediately reveals the Wanderer card (Magoi already there)",
			announceIndex == 2
		)
	end

	do
		local data = fakeRankData(0, 0, 0, "The Sand-Born") -- origin already answered
		local oldIndex, newIndex = RankService.ApplyMagoi(data, 1500) -- 0 -> 1500: Street Rat -> Renowned in one grant
		expect(results, "RankService H1: a big grant reaches Renowned (index 4) in one step", oldIndex == 1 and newIndex == 4)

		local first = RankService.NextRankToAnnounce(data, oldIndex, newIndex)
		expect(results, "RankService H1: the first card announced is Wanderer, not the top rank", first == 2)

		data.Progress.PendingEpithet = { rank = first :: number, choices = { "X", "Y", "Z" } }
		local okWanderer = RankService.ApplyChooseEpithet(data, 1)
		local second = RankService.NextRankAfterChoice(data, first :: number)
		expect(results, "RankService H1: answering Wanderer immediately reveals Adventurer next", okWanderer and second == 3)

		data.Progress.PendingEpithet = { rank = second :: number, choices = { "X", "Y", "Z" } }
		local okAdventurer = RankService.ApplyChooseEpithet(data, 1)
		local third = RankService.NextRankAfterChoice(data, second :: number)
		expect(results, "RankService H1: answering Adventurer immediately reveals Renowned next", okAdventurer and third == 4)

		data.Progress.PendingEpithet = { rank = third :: number, choices = { "X", "Y", "Z" } }
		local okRenowned = RankService.ApplyChooseEpithet(data, 1)
		local fourth = RankService.NextRankAfterChoice(data, third :: number)
		expect(results, "RankService H1: once caught up to the actual rank, nothing more is announced", okRenowned and fourth == nil)
	end
end

-- M5A-01: Economy's rounding rule and EconomyService's pure core, both
-- exercised with no Player/DataService involved - Affords/ApplyPay/
-- ApplyGive/ApplySet only ever touch data.Economy.
local function fakeEconomyData(copper: number, silver: number, gold: number): SaveSchema.Data
	return ({
		Economy = { Copper = copper, Silver = silver, Gold = gold },
	} :: any) :: SaveSchema.Data
end

local function testEconomy(results: { Check })
	-- Bryan's price-band table (M5-PLAN.md Phase 5A, replaced 2026-09-29:
	-- bands, not rounding). 200/201 and 10,000/10,001 are the sharpest
	-- cases - one Copper past a full 100/10,000 is what actually crosses
	-- into the next band, not a rounding midpoint (see Economy.toPrice's
	-- own comment).
	for _, example in Economy.PriceExamples do
		local coin, amount = Economy.toPrice(example.copper)
		expect(
			results,
			string.format("Economy: toPrice(%d) = %s", example.copper, Economy.format(example.coin, example.amount)),
			coin == example.coin and amount == example.amount
		)
	end

	expect(results, "Economy: format renders \"N Coin\"", Economy.format("Silver", 3) == "3 Silver")

	-- roundReward is the same rule as toPrice (kept for the Bank milestone,
	-- unused today - see its own comment and GiveCopperValue below).
	do
		local coin, amount = Economy.roundReward(5000)
		expect(results, "Economy: roundReward follows the same banding rule as toPrice", coin == "Silver" and amount == 49)
	end

	-- CanAfford/Pay are exact-coin only: 120 Copper can't pay a 1-Silver
	-- price, even though 120 Copper is worth more than 1 Silver converted.
	do
		local data = fakeEconomyData(120, 0, 0)
		expect(results, "EconomyService: Affords is exact-coin only (120 Copper can't afford 1 Silver)", not EconomyService.Affords(data, "Silver", 1))

		local ok, failure = EconomyService.ApplyPay(data, "Silver", 1)
		expect(
			results,
			"EconomyService: ApplyPay(Silver, 1) against 120 Copper fails as \"convert\" (enough wealth, wrong coin)",
			not ok and failure == "convert"
		)
		expect(results, "EconomyService: a failed Pay leaves the wallet untouched", data.Economy.Copper == 120 and data.Economy.Silver == 0)
	end

	-- Not enough wealth in ANY coin fails as "no" instead (the old
	-- MarketHandler NeedMoney line, not the Convert one).
	do
		local data = fakeEconomyData(0, 0, 0)
		local ok, failure = EconomyService.ApplyPay(data, "Silver", 1)
		expect(results, "EconomyService: ApplyPay against an empty wallet fails as \"no\" (not enough money at all)", not ok and failure == "no")
	end

	-- REVIEW-M5A-01 L1: a bad amount (less than 1, or not a whole number)
	-- is rejected as "no" before it ever touches the wallet, even against a
	-- wallet that could otherwise afford it.
	do
		local data = fakeEconomyData(0, 5, 0)
		local okZero, failureZero = EconomyService.ApplyPay(data, "Silver", 0)
		expect(results, "EconomyService (L1): ApplyPay rejects an amount below 1", not okZero and failureZero == "no")

		local okNegative, failureNegative = EconomyService.ApplyPay(data, "Silver", -1)
		expect(results, "EconomyService (L1): ApplyPay rejects a negative amount", not okNegative and failureNegative == "no")

		local okFraction, failureFraction = EconomyService.ApplyPay(data, "Silver", 1.5)
		expect(results, "EconomyService (L1): ApplyPay rejects a non-integer amount", not okFraction and failureFraction == "no")

		expect(results, "EconomyService (L1): none of the rejected amounts touched the wallet", data.Economy.Silver == 5)
	end

	-- A payment that CAN be made in the exact coin succeeds and only moves
	-- that one coin.
	do
		local data = fakeEconomyData(0, 5, 0)
		local ok = EconomyService.ApplyPay(data, "Silver", 2)
		expect(results, "EconomyService: ApplyPay succeeds when the exact coin covers the price", ok and data.Economy.Silver == 3)
	end

	-- Give never goes negative: a dev `.coins+` with a negative number can
	-- empty a coin but not push it below 0.
	do
		local data = fakeEconomyData(20, 0, 0)
		EconomyService.ApplyGive(data, "Copper", -1000)
		expect(results, "EconomyService: ApplyGive clamps the wallet at 0", data.Economy.Copper == 0)
	end

	-- ApplySet (the dev `.coins` set form) clamps and floors every coin.
	do
		local data = fakeEconomyData(0, 0, 0)
		EconomyService.ApplySet(data, -5, 2.7, 10)
		expect(
			results,
			"EconomyService: ApplySet clamps negatives at 0 and floors fractions",
			data.Economy.Copper == 0 and data.Economy.Silver == 2 and data.Economy.Gold == 10
		)
	end

	-- Bryan's refinement (2026-09-29): rewards pay Copper only for now -
	-- GiveCopperValue is exactly ApplyGive(data, "Copper", copper), which
	-- never rounds into Silver/Gold the way Economy.roundReward would (a
	-- 5,000-Copper reward stays 5,000 Copper, not 50 Silver).
	do
		local data = fakeEconomyData(0, 0, 0)
		EconomyService.ApplyGive(data, "Copper", 5000)
		expect(
			results,
			"EconomyService: a Copper reward doesn't round into Silver/Gold (Bryan's refinement, 2026-09-29)",
			data.Economy.Copper == 5000 and data.Economy.Silver == 0 and data.Economy.Gold == 0
		)
	end
end

-- M5B-01: Shop's colour rolls/prices and ItemService/ShopService's pure
-- decision core, all exercised with no Instance/Player/DataService involved.
local function testShop(results: { Check })
	-- Colour roll: StandardColors is White(80)/Tan(25)/Black(10), a
	-- deterministic `roll` (1..115) picks a bucket without touching
	-- math.random.
	expect(results, "Shop: colour roll picks White at the bottom of its 80-wide band (roll 1)", Shop.RollColor(Shop.StandardColors, 1).name == "White")
	expect(results, "Shop: colour roll picks White at the top of its band (roll 80)", Shop.RollColor(Shop.StandardColors, 80).name == "White")
	expect(results, "Shop: colour roll picks Tan at the bottom of its band (roll 81)", Shop.RollColor(Shop.StandardColors, 81).name == "Tan")
	expect(results, "Shop: colour roll picks Tan at the top of its band (roll 105)", Shop.RollColor(Shop.StandardColors, 105).name == "Tan")
	expect(results, "Shop: colour roll picks Black at the bottom of its band (roll 106)", Shop.RollColor(Shop.StandardColors, 106).name == "Black")
	expect(results, "Shop: colour roll picks Black at the top of the pool (roll 115)", Shop.RollColor(Shop.StandardColors, 115).name == "Black")

	-- Prices: base 80 Copper (Qarzin's Clothing resource, ratio 1), *1.2 for
	-- hats and *1.5 for cloaks (old MarketHandler numbers), then the rolled
	-- colour's own multiplier (White x1, Tan x1.25, Black x1.5) - see
	-- Shop.luau's own derivation comment. Shirts always roll from
	-- VarietyColors, which never carries a multiplier.
	local white, tan, black = Shop.StandardColors[1], Shop.StandardColors[2], Shop.StandardColors[3]
	expect(results, "Shop: hat price, White = 96 Copper", Shop.PriceFor("H", white) == 96)
	expect(results, "Shop: hat price, Tan = 120 Copper", Shop.PriceFor("H", tan) == 120)
	expect(results, "Shop: hat price, Black = 144 Copper", Shop.PriceFor("H", black) == 144)
	expect(results, "Shop: cloak price, White = 120 Copper", Shop.PriceFor("C", white) == 120)
	expect(results, "Shop: cloak price, Tan = 150 Copper", Shop.PriceFor("C", tan) == 150)
	expect(results, "Shop: cloak price, Black = 180 Copper", Shop.PriceFor("C", black) == 180)
	expect(results, "Shop: pants price, White = 80 Copper", Shop.PriceFor("P", white) == 80)
	expect(results, "Shop: pants price, Tan = 100 Copper", Shop.PriceFor("P", tan) == 100)
	expect(results, "Shop: pants price, Black = 120 Copper", Shop.PriceFor("P", black) == 120)
	expect(results, "Shop: shirt price never carries a colour multiplier (Variety pool)", Shop.PriceFor("S", Shop.VarietyColors[1]) == 80)

	-- Every price above bands through Economy.toPrice the same as any other
	-- price in the game (Bryan 2026-09-29: shown through the 5A band rule).
	do
		local coin: Economy.Coin, amount: number = Economy.toPrice(Shop.PriceFor("C", black))
		expect(results, "Shop: a 180-Copper cloak bands to 1 Silver", coin == "Silver" and amount == 1)
	end

	-- Pools exclude the rags (docs/reference/m5b-studio-dump.md #4): the
	-- starter shirt/pants stay out of the shop via forSale = false, not a
	-- separate pool.
	local shirtRagsExcluded, pantsRagsExcluded = true, true
	for _, item in Shop.Shirts do
		if item.name == "Short Sleeve Rags" and item.forSale then
			shirtRagsExcluded = false
		end
	end
	for _, item in Shop.Pants do
		if (item.name == "Shoes and Rags" or item.name == "Barefooted and Rags") and item.forSale then
			pantsRagsExcluded = false
		end
	end
	expect(results, "Shop: the starter rag shirt is not for sale", shirtRagsExcluded)
	expect(results, "Shop: the starter rag pants are not for sale", pantsRagsExcluded)
	expect(results, "Shop: ForSale filters out exactly the one rag shirt", #Shop.ForSale(Shop.Shirts) == #Shop.Shirts - 1)
	expect(
		results,
		"Shop: the pants pool has one for-sale entry today, with room for more (Bryan 2026-09-29)",
		#Shop.ForSale(Shop.Pants) == 1 and #Shop.Pants > 1
	)
end

local function fakeGearData(shirt: string, pants: string, hats: { string }): SaveSchema.Data
	return ({
		Gear = { Shirt = shirt, Pants = pants, Hats = hats, Inventory = {} },
	} :: any) :: SaveSchema.Data
end

local function testItemService(results: { Check })
	-- Encode/decode round-trips the "type|name|r,g,b" format unchanged from
	-- the old ItemHandler.
	local code = ItemService.Encode("S", "Vest", "255,0,0")
	local itemType, name, colorCode = ItemService.Decode(code)
	expect(results, "ItemService: encode/decode round-trips", itemType == "S" and name == "Vest" and colorCode == "255,0,0")
	expect(results, "ItemService: ClothingId finds a real shirt id", ItemService.ClothingId("S", "Vest") ~= nil)
	expect(results, "ItemService: ClothingId returns nil for an unknown name", ItemService.ClothingId("S", "Nonexistent") == nil)

	-- Owns is colour-aware (REVIEW/AUDIT fix, M5-PLAN.md Phase 5B): owning a
	-- Black Vest must not match a White Vest of the same item.
	local worn = fakeGearData(ItemService.Encode("S", "Vest", "35,35,35"), "", { "", "", "" })
	expect(results, "ItemService: Owns matches the exact item+colour worn", ItemService.Owns(worn, ItemService.Encode("S", "Vest", "35,35,35")))
	expect(
		results,
		"ItemService: Owns does NOT match the same item in a different colour",
		not ItemService.Owns(worn, ItemService.Encode("S", "Vest", "255,255,255"))
	)
	expect(results, "ItemService: Owns is false for an item never worn", not ItemService.Owns(worn, ItemService.Encode("P", "Standard", "35,35,35")))

	-- HasFreeHatSlot - hats and cloaks share the same 3-slot Gear.Hats
	-- array; ShopService checks this BEFORE EconomyService.Pay ever runs.
	local emptySlots = fakeGearData("", "", { "", "", "" })
	expect(results, "ItemService: HasFreeHatSlot is true with 3 empty slots", ItemService.HasFreeHatSlot(emptySlots))
	local fullSlots = fakeGearData("", "", { "H|Cowl|1,1,1", "C|Torn Cloak|1,1,1", "H|Feather|1,1,1" })
	expect(results, "ItemService: HasFreeHatSlot is false once all 3 slots are used", not ItemService.HasFreeHatSlot(fullSlots))
	expect(results, "ItemService: Owns finds an exact match among the 3 Hats slots", ItemService.Owns(fullSlots, "H|Cowl|1,1,1"))
end

local function testShopService(results: { Check })
	-- ShopService.Decide is the pure gate every purchase runs through
	-- BEFORE EconomyService.Pay is ever called (M5-PLAN.md Phase 5B: "all
	-- checks run BEFORE any charge"). Proving Decide returns "slotsFull"/
	-- "owned" here, with no EconomyService involved at all, is exactly
	-- "Pay is not called when slots are full/the item is already owned" -
	-- the Triggered handler only reaches EconomyService.Pay once Decide
	-- returns "ok".
	local fullSlots = fakeGearData("", "", { "H|Cowl|1,1,1", "C|Torn Cloak|1,1,1", "H|Feather|1,1,1" })
	expect(
		results,
		"ShopService: Decide blocks a hat purchase before Pay would run when all 3 slots are full",
		ShopService.Decide(fullSlots, "H", "H|Fancy Turban|1,1,1") == "slotsFull"
	)
	expect(
		results,
		"ShopService: Decide blocks a cloak purchase too (hats and cloaks share the same slots)",
		ShopService.Decide(fullSlots, "C", "C|Long Wrap|1,1,1") == "slotsFull"
	)

	local ownsWhiteVest = fakeGearData(ItemService.Encode("S", "Vest", "255,255,255"), "", { "", "", "" })
	expect(
		results,
		"ShopService: Decide blocks buying the exact item+colour already owned",
		ShopService.Decide(ownsWhiteVest, "S", ItemService.Encode("S", "Vest", "255,255,255")) == "owned"
	)
	expect(
		results,
		"ShopService: Decide allows the same item in a different colour (the old MarketHandler bug this fixes)",
		ShopService.Decide(ownsWhiteVest, "S", ItemService.Encode("S", "Vest", "35,35,35")) == "ok"
	)

	local fresh = fakeGearData("", "", { "", "", "" })
	expect(results, "ShopService: Decide allows a legitimate new purchase", ShopService.Decide(fresh, "P", "P|Standard|255,255,255") == "ok")
end

-- M3-01: StatusService's Apply/Remove/Has/expiry and bridge/attribute
-- mirroring, exercised against plain (never PlayerService.Ready'd) Model
-- instances rather than a real character. REVIEW-M3-01 H2: the test
-- models are parented under a scratch ServerStorage folder (destroyed at
-- the end) instead of left with no Parent at all, so the shared expiry
-- loop (which unregisters anything with Parent == nil) doesn't yank them
-- out from under the test mid-way through.
local function testStatusService(results: { Check })
	local scratch = Instance.new("Folder")
	scratch.Name = "SelfTestStatusService"
	scratch.Parent = ServerStorage

	do
		local character = Instance.new("Model")
		character.Parent = scratch

		local activeFires, inactiveFires = 0, 0
		local conn = StatusService.Changed:Connect(function(firedCharacter, status, active)
			if firedCharacter == character and status == "Stun" then
				if active then
					activeFires += 1
				else
					inactiveFires += 1
				end
			end
		end)

		StatusService.Register(character)

		-- BUG-26 (M3-FIX2-S): the M3-FIX-S rewrite still asserted right
		-- after a FIXED task.wait(n) - correct in spirit (a Deferred
		-- signal handler needs a yield to actually run at all, and a real
		-- duration needs real time to pass before it can expire), but a
		-- fixed wait can never be PROVEN long enough: Studio's own
		-- task.wait is only a lower bound (it can overshoot under load,
		-- especially right when the self-test runs, just after server
		-- start), so "one task.wait() always flushes the deferred queue"
		-- and "0.1s of wait never overshoots a 1.0s+0.3s budget" were both
		-- still schedule-dependent guesses, not proofs. `pollUntil` (above)
		-- removes the guess: each assertion below only runs once the
		-- condition it checks is actually true, or a generous multi-second
		-- deadline is reached - so it passes or fails on what the code
		-- did, not on how fast this particular tick ran. StatusService's
		-- Apply/Remove/shared expiry loop are unchanged and correct; every
		-- fix in this block is test-side.
		local DURATION = 2

		StatusService.Apply(character, "Stun", DURATION)
		pollUntil(1, function()
			return activeFires >= 1
		end)
		expect(results, "StatusService: Apply makes Has true", StatusService.Has(character, "Stun"))
		expect(
			results,
			"StatusService: attribute mirrors an active status",
			character:GetAttribute("Stunned") == true
		)
		expect(results, "StatusService: Changed fires exactly once on Apply", activeFires == 1)

		-- Refresh immediately (DURATION is generous enough that even the
		-- poll above, worst case, can't have eaten into it): re-Apply
		-- before expiry must push the expiry back out, and must not
		-- re-fire Changed (the active state didn't change). There's
		-- nothing to poll FOR here (no state transition to wait on), so a
		-- few bare yields just give any wrongly-fired deferred event a
		-- chance to show up before the "still 1" check.
		StatusService.Apply(character, "Stun", DURATION)
		task.wait()
		task.wait()
		task.wait()
		expect(results, "StatusService: re-Apply refreshes the duration", StatusService.Has(character, "Stun"))
		expect(results, "StatusService: a refreshing re-Apply doesn't re-fire Changed", activeFires == 1)

		-- "a window that ends only after the loop has ticked at least
		-- once past expiry": poll for Has actually clearing (which can
		-- only happen once the shared expiry loop has run at least one
		-- tick past the refreshed expiresAt), not a fixed wait sized to
		-- guess when that tick will have happened.
		pollUntil(DURATION + 2, function()
			return not StatusService.Has(character, "Stun")
		end)
		expect(results, "StatusService: an expired duration clears Has", not StatusService.Has(character, "Stun"))
		expect(
			results,
			"StatusService: attribute clears once the status expires",
			character:GetAttribute("Stunned") == false
		)
		pollUntil(1, function()
			return inactiveFires >= 1
		end)
		expect(results, "StatusService: Changed fires exactly once on expiry", inactiveFires == 1)

		conn:Disconnect()

		-- REVIEW-M3-01 L4: Block's parry window (value 1) flips itself to
		-- the block hold (value 0) on the shared loop, without anything
		-- re-Applying.
		StatusService.Apply(character, "Block", nil, { value = 1 })
		expect(results, "StatusService: Has is true right after Apply", StatusService.Has(character, "Block"))

		task.wait(Combat.Block.parryWindow + 0.15)
		local blockInfo = StatusService.Get(character, "Block")
		expect(
			results,
			"StatusService: Block's parry window flips itself to a block hold (value 0)",
			StatusService.Has(character, "Block") and blockInfo ~= nil and (blockInfo.data :: any).value == 0
		)

		StatusService.Remove(character, "Block")
		expect(results, "StatusService: Has is false right after Remove", not StatusService.Has(character, "Block"))

		StatusService.Unregister(character)
		character:Destroy()
	end

	-- AUDIT M18: applying to (or removing from, or querying) a character
	-- that's already gone must never error.
	do
		local character = Instance.new("Model")
		character.Parent = scratch
		character:Destroy()

		local okApply = pcall(StatusService.Apply, character, "Stun", 1)
		expect(results, "StatusService: Apply on a destroyed model doesn't error", okApply)

		local okRemove = pcall(StatusService.Remove, character, "Stun")
		expect(results, "StatusService: Remove on a destroyed model doesn't error", okRemove)

		local okHas, hasResult = pcall(StatusService.Has, character, "Stun")
		expect(
			results,
			"StatusService: Has on a destroyed model doesn't error and reports false",
			okHas and hasResult == false
		)
	end

	scratch:Destroy()
end

-- M3-02: MovementService's pure helpers (stack math, dash cooldown,
-- low-health thresholds), the same "test the math directly" approach as
-- HealthService's self-test.
local function testMovementService(results: { Check })
	do
		expect(results, "MovementService: no modifiers is 1.0 (full speed)", MovementService.EffectiveMultiplier({}) == 1.0)
		expect(
			results,
			"MovementService: the smallest active modifier wins",
			MovementService.EffectiveMultiplier({ Run = 1.75, Block = 0.6 }) == 0.6
		)
		expect(
			results,
			"MovementService: a 0 modifier freezes",
			MovementService.EffectiveMultiplier({ Run = 1.75, TrueStun = 0 }) == 0
		)
		expect(
			results,
			"MovementService: clearing the only modifier restores 1.0",
			MovementService.EffectiveMultiplier({}) == 1.0
		)
	end

	do
		expect(
			results,
			"MovementService: CanDash with no prior dash is allowed",
			MovementService.CanDash(100, nil, 1.2)
		)
		expect(
			results,
			"MovementService: CanDash rejects a second dash inside the cooldown",
			not MovementService.CanDash(100.5, 100, 1.2)
		)
		expect(
			results,
			"MovementService: CanDash allows a dash once the cooldown has fully elapsed",
			MovementService.CanDash(101.2, 100, 1.2)
		)
	end

	do
		expect(
			results,
			"MovementService: LowHealthMult at full health (walking) is 1.0",
			MovementService.LowHealthMult(false, 1) == 1.0
		)
		expect(
			results,
			"MovementService: LowHealthMult at 0 health (walking) is a quarter",
			MovementService.LowHealthMult(false, 0) == 0.25
		)
		expect(
			results,
			"MovementService: LowHealthMult at full health (running) is Combat.Run.speedMult",
			math.abs(MovementService.LowHealthMult(true, 1) - 1.75) < 1e-9
		)
		expect(
			results,
			"MovementService: LowHealthMult at 0 health (running) is half of Combat.Run.speedMult",
			math.abs(MovementService.LowHealthMult(true, 0) - 0.875) < 1e-9
		)
		expect(
			results,
			"MovementService: LowHealthMult clamps an out-of-range ratio",
			MovementService.LowHealthMult(false, 5) == 1.0 and MovementService.LowHealthMult(false, -5) == 0.25
		)
	end

	-- REVIEW-M3-02 #3: the Dash bridge marker used to never clear
	-- (ClearModifier bailed on a missing entry.modifiers entry, since the
	-- marker was written directly through writeBridgeModifier instead of
	-- SetModifier). IntFold/IntFold.MovementSpeed are pre-created here so
	-- MovementService's own background bridge resolution (normally a
	-- bounded real-time wait) resolves synchronously inside Register.
	do
		local scratch = Instance.new("Folder")
		scratch.Name = "SelfTestMovementServiceDash"
		scratch.Parent = ServerStorage

		local character = Instance.new("Model")
		character.Parent = scratch
		local intFold = Instance.new("Folder")
		intFold.Name = "IntFold"
		intFold.Parent = character
		local movementSpeed = Instance.new("Folder")
		movementSpeed.Name = "MovementSpeed"
		movementSpeed.Parent = intFold
		local hrp = Instance.new("Part")
		hrp.Name = "HumanoidRootPart"
		hrp.Anchored = true
		hrp.CFrame = CFrame.new(0, 5, 0)
		hrp.Parent = character
		local humanoid = Instance.new("Humanoid")
		humanoid.Parent = character

		MovementService.Register(character)
		local dashed = MovementService.Dash(character, 0, 1)
		expect(results, "MovementService: Dash succeeds with no prior dash", dashed)
		expect(
			results,
			"MovementService: Dash writes a transient IntFold.MovementSpeed.Dash bridge child",
			movementSpeed:FindFirstChild("Dash") ~= nil
		)

		task.wait(Combat.Dash.duration + 0.1)
		expect(
			results,
			"MovementService: the Dash bridge child clears itself after the dash duration",
			movementSpeed:FindFirstChild("Dash") == nil
		)

		MovementService.Unregister(character)
		character:Destroy()
		scratch:Destroy()
	end
end

-- M3-03/M3-FIX3-S/M3-FIX4-S: CombatService's pure facing/block-decision
-- helpers, the hit-check geometry against fake models parented in
-- Workspace (spatial queries only find parts actually in the DataModel),
-- knockout at 0 HP, the AttackStart/AttackHit/AttackCancel chain-hit
-- sequence (window/order checks, per-hit cancel, Light/Heavy interrupts),
-- feints, bleed and the count-based knockback, and the NPC server-timed
-- sequence. Block's meter-drain (HealthService.SpendBlock) needs a real
-- Player and is exercised by the playtester instead - ResolveBlock's own
-- pure test below covers the decision logic that path feeds into.
local function testCombatService(results: { Check })
	do
		expect(
			results,
			"CombatService: IsFacingAttacker true when the target looks back at the attacker",
			CombatService.IsFacingAttacker(Vector3.new(0, 0, -1), Vector3.new(0, 0, 2), Vector3.new(0, 0, 0))
		)
		expect(
			results,
			"CombatService: IsFacingAttacker false when the target faces away",
			not CombatService.IsFacingAttacker(Vector3.new(0, 0, 1), Vector3.new(0, 0, 2), Vector3.new(0, 0, 0))
		)
	end

	do
		expect(results, "CombatService: ResolveBlock parries when not on cooldown", CombatService.ResolveBlock(true, false, true) == "Parried")
		expect(
			results,
			"CombatService: ResolveBlock (AUDIT H5) falls back to a held block on parry cooldown",
			CombatService.ResolveBlock(true, true, true) == "Blocked"
		)
		expect(results, "CombatService: ResolveBlock holds while the meter lasts", CombatService.ResolveBlock(false, false, true) == "Blocked")
		expect(
			results,
			"CombatService: ResolveBlock breaks once the meter is empty",
			CombatService.ResolveBlock(false, false, false) == "BlockBroken"
		)
	end

	local scratch = Instance.new("Folder")
	scratch.Name = "SelfTestCombatService"
	scratch.Parent = Workspace

	local function buildFakeCombatant(name: string, position: Vector3, lookAt: Vector3): Model
		local model = Instance.new("Model")
		model.Name = name

		local hrp = Instance.new("Part")
		hrp.Name = "HumanoidRootPart"
		hrp.Size = Vector3.new(2, 2, 1)
		hrp.Anchored = true
		hrp.CanCollide = false
		hrp.CFrame = CFrame.new(position, lookAt)
		hrp.Parent = model

		local humanoid = Instance.new("Humanoid")
		humanoid.MaxHealth = 100
		humanoid.Health = 100
		humanoid.Parent = model

		model.Parent = scratch
		return model
	end

	local fist = Combat.styleFor("Fist") :: Combat.Style
	local dagger = Combat.styleFor("Dagger") :: Combat.Style

	do
		local attacker = buildFakeCombatant("SelfTestAttacker", Vector3.new(500, 5, 0), Vector3.new(500, 5, 1))
		local hit = fist.chain[1]

		local inRange = buildFakeCombatant("SelfTestInRange", Vector3.new(500, 5, 3), Vector3.new(500, 5, 4))
		local outOfRange = buildFakeCombatant("SelfTestOutOfRange", Vector3.new(500, 5, 50), Vector3.new(500, 5, 51))
		local behind = buildFakeCombatant("SelfTestBehind", Vector3.new(500, 5, -3), Vector3.new(500, 5, -4))

		-- REVIEW-M3-03 M5: only a registered combatant can be hit.
		CombatService.Register(inRange, nil, "Fist")
		CombatService.Register(outOfRange, nil, "Fist")
		CombatService.Register(behind, nil, "Fist")

		expect(results, "CombatService: FindTarget finds a combatant in range", CombatService.FindTarget(attacker, hit) == inRange)

		inRange:Destroy()
		expect(
			results,
			"CombatService: FindTarget finds neither an out-of-range nor a behind-the-attacker combatant",
			CombatService.FindTarget(attacker, hit) == nil
		)

		CombatService.Unregister(inRange)
		CombatService.Unregister(outOfRange)
		CombatService.Unregister(behind)
		outOfRange:Destroy()
		behind:Destroy()
		attacker:Destroy()
	end

	do
		local attacker = buildFakeCombatant("SelfTestUnregisteredAttacker", Vector3.new(700, 5, 0), Vector3.new(700, 5, 1))
		local hit = fist.chain[1]
		local unregisteredTarget = buildFakeCombatant("SelfTestUnregisteredTarget", Vector3.new(700, 5, 3), Vector3.new(700, 5, 4))

		expect(results, "CombatService: FindTarget (M5) never hits an unregistered combatant", CombatService.FindTarget(attacker, hit) == nil)

		unregisteredTarget:Destroy()
		attacker:Destroy()
	end

	do
		local attacker = buildFakeCombatant("SelfTestKnockoutAttacker", Vector3.new(600, 5, 0), Vector3.new(600, 5, 1))
		local target = buildFakeCombatant("SelfTestKnockoutTarget", Vector3.new(600, 5, 3), Vector3.new(600, 5, 0))
		StatusService.Register(target)

		local targetHumanoid = target:FindFirstChildOfClass("Humanoid") :: Humanoid
		targetHumanoid.Health = 3 -- less than the Jab's 4 damage

		local hit = fist.chain[1]
		CombatService.ApplyHit(attacker, target, fist, hit, 1)

		expect(results, "CombatService: a lethal hit knocks out instead of killing", targetHumanoid.Health == 1)
		expect(results, "CombatService: knockout applies the Knocked status", StatusService.Has(target, "Knocked"))

		StatusService.Unregister(target)
		target:Destroy()
		attacker:Destroy()
	end

	do
		local character = Instance.new("Model")
		character.Parent = scratch
		local hrp = Instance.new("Part")
		hrp.Name = "HumanoidRootPart"
		hrp.Anchored = true
		hrp.Parent = character
		local humanoid = Instance.new("Humanoid")
		humanoid.Parent = character

		StatusService.Register(character)
		CombatService.Register(character, nil, "Fist")
		StatusService.Apply(character, "Stun", 5)

		local started = CombatService.AttackStart(character)
		expect(
			results,
			"CombatService: AttackStart while stunned is rejected",
			started == false and character:GetAttribute("Attacking") ~= true and (character:GetAttribute("NextAttackAt") :: number) == 0
		)

		StatusService.Unregister(character)
		CombatService.Unregister(character)
		character:Destroy()
	end

	-- REVIEW-M3-03 L8 / REVIEW-M3-04 L1: the full parry-window -> cooldown
	-- -> held -> broken sequence, against a fake (no-Player) blocker - which
	-- only works at all because a target with no real Player gets its own
	-- HealthService-backed block meter now (via HealthService.Register, the
	-- same as NpcService gives a real NPC). Uses the Heavy (blockDrain 45,
	-- M3-FIX4-S: per-hit now, not the old flat Combat.Block.drainPerHit):
	-- 100 -(parry, no drain)-> 100 -(cooldown-forced hold, -45)-> 55
	-- -(still holds, -45)-> 10 -(45 needed, only 10 left: breaks).
	do
		local attacker = buildFakeCombatant("SelfTestParryAttacker", Vector3.new(800, 5, 0), Vector3.new(800, 5, 1))
		local blocker = buildFakeCombatant("SelfTestParryBlocker", Vector3.new(800, 5, 2), Vector3.new(800, 5, 0))
		HealthService.Register(blocker, { maxHealth = 100 })
		StatusService.Register(attacker)
		StatusService.Register(blocker)
		CombatService.Register(attacker, nil, "Fist")
		CombatService.Register(blocker, nil, "Fist")

		local blockerHumanoid = blocker:FindFirstChildOfClass("Humanoid") :: Humanoid
		local heavy = fist.chain[2]

		StatusService.Apply(blocker, "Block", nil, { value = 1 })

		CombatService.ApplyHit(attacker, blocker, fist, heavy, 2)
		expect(
			results,
			"CombatService: a parry stuns the attacker and costs no block HP (M1)",
			StatusService.Has(attacker, "Stun") and blockerHumanoid.Health == 100
		)

		StatusService.Remove(attacker, "Stun")
		CombatService.ApplyHit(attacker, blocker, fist, heavy, 2) -- 100 -> 55
		expect(
			results,
			"CombatService: a second hit right after a parry can't parry again (AUDIT H5 cooldown) and drains the meter instead",
			not StatusService.Has(attacker, "Stun") and StatusService.Has(blocker, "Block") and blockerHumanoid.Health == 100
		)

		task.wait(Combat.Block.parryCooldown + Combat.Block.parryWindow + 0.1)
		local blockInfoAfter = StatusService.Get(blocker, "Block")
		expect(
			results,
			"CombatService: once the cooldown and parry window elapse, a hit just holds the block",
			blockInfoAfter ~= nil and (blockInfoAfter.data :: any).value == 0
		)

		CombatService.ApplyHit(attacker, blocker, fist, heavy, 2) -- 55 -> 10
		expect(results, "CombatService: the block still holds while the meter lasts", StatusService.Has(blocker, "Block"))

		CombatService.ApplyHit(attacker, blocker, fist, heavy, 2) -- 10 < 45: breaks
		expect(results, "CombatService: the block breaks once a no-Player target's meter runs out (L8)", not StatusService.Has(blocker, "Block"))
		expect(results, "CombatService: a broken block applies TrueStun", StatusService.Has(blocker, "TrueStun"))

		HealthService.Unregister(blocker)
		StatusService.Unregister(attacker)
		StatusService.Unregister(blocker)
		CombatService.Unregister(attacker)
		CombatService.Unregister(blocker)
		attacker:Destroy()
		blocker:Destroy()
	end

	-- M3-FIX3-S/M3-FIX4-S: the animation-marker chain-hit sequence -
	-- order/window checks. Nothing here asserts an UPPER bound on how much
	-- time has passed right after a task.wait (BUG-23/BUG-26: task.wait is
	-- a lower bound only, and Studio can overshoot it) - only that "clearly
	-- too early" and "clearly too late" reports get dropped, with wide
	-- margins either side, and that index-mismatch rejections (duplicate/
	-- out-of-order) are timing-independent altogether.
	do
		local attacker = buildFakeCombatant("SelfTestHitAttacker", Vector3.new(900, 5, 0), Vector3.new(900, 5, 1))
		StatusService.Register(attacker)
		CombatService.Register(attacker, nil, "Fist")

		local startedAt = Workspace:GetServerTimeNow()
		local started = CombatService.AttackStart(attacker)
		expect(results, "CombatService: AttackStart begins an attack and sets Attacking", started == true and attacker:GetAttribute("Attacking") == true)

		-- REVIEW-M3-FIX3-S M1: waits are measured against CombatService's OWN
		-- clock (Workspace:GetServerTimeNow(), matching attack.startedAt) and
		-- top up to a target ELAPSED time rather than chaining fixed waits, so
		-- an earlier task.wait's overshoot (BUG-23/BUG-26: it's a lower bound
		-- only) can't push a later check past the watchdog by surprise.
		local function waitUntilElapsed(targetElapsed: number)
			local remaining = targetElapsed - (Workspace:GetServerTimeNow() - startedAt)
			if remaining > 0 then
				task.wait(remaining)
			end
		end

		CombatService.AttackHit(attacker, 1) -- reported immediately: well before hit 1's window opens
		expect(
			results,
			"CombatService: an AttackHit reported too early is dropped (hit 1 not consumed)",
			attacker:GetAttribute("Attacking") == true
		)

		waitUntilElapsed((fist.chain[1].hitWindow.min + fist.chain[1].hitWindow.max) / 2) -- safely inside hit 1's window
		CombatService.AttackHit(attacker, 1) -- the real, accepted report
		CombatService.AttackHit(attacker, 1) -- a duplicate report for the same, now-landed hit
		expect(
			results,
			"CombatService: a duplicate AttackHit for a landed hit is dropped, not double-counted",
			attacker:GetAttribute("Attacking") == true
		)

		CombatService.AttackHit(attacker, 5) -- wildly out of order
		expect(results, "CombatService: an out-of-order AttackHit index is dropped", attacker:GetAttribute("Attacking") == true)

		-- M3-FIX4-S: cancel is per-hit now - hit 1 (Jab) already landed, but
		-- hit 2 (Heavy) is the new "next unlanded hit", and elapsed so far
		-- (~hit 1's own window midpoint) is still well inside HEAVY's own
		-- cancelUntil (1.05s) - so this is accepted, unlike the old flat
		-- "only before hit 1 lands" rule.
		CombatService.AttackCancel(attacker)
		expect(
			results,
			"CombatService: AttackCancel is honoured for hit 2 while inside ITS OWN cancelUntil, even though hit 1 already landed",
			attacker:GetAttribute("Attacking") == false
		)

		StatusService.Unregister(attacker)
		CombatService.Unregister(attacker)
		attacker:Destroy()
	end

	do
		local attacker = buildFakeCombatant("SelfTestHitTooLateAttacker", Vector3.new(920, 5, 0), Vector3.new(920, 5, 1))
		StatusService.Register(attacker)
		CombatService.Register(attacker, nil, "Fist")

		local tolerance = Config.Combat.HitTolerance
		local startedAt = Workspace:GetServerTimeNow()
		CombatService.AttackStart(attacker)

		local function waitUntilElapsed(targetElapsed: number)
			local remaining = targetElapsed - (Workspace:GetServerTimeNow() - startedAt)
			if remaining > 0 then
				task.wait(remaining)
			end
		end

		waitUntilElapsed((fist.chain[1].hitWindow.min + fist.chain[1].hitWindow.max) / 2)
		CombatService.AttackHit(attacker, 1) -- lands, nextHit becomes 2

		-- Just past hit 2's window (elapsed target: max + tolerance + 0.1),
		-- but well short of the watchdog (max + tolerance + style.timeout =
		-- 1.5s later still) - late enough to be rejected, not so late the
		-- watchdog has already ended the attack out from under this check.
		waitUntilElapsed(fist.chain[2].hitWindow.max + tolerance + 0.1)
		CombatService.AttackHit(attacker, 2)
		expect(
			results,
			"CombatService: an AttackHit reported after its window closes (too late) is dropped",
			attacker:GetAttribute("Attacking") == true
		)

		StatusService.Unregister(attacker)
		CombatService.Unregister(attacker)
		attacker:Destroy()
	end

	do
		local attacker = buildFakeCombatant("SelfTestCancelAttacker", Vector3.new(950, 5, 0), Vector3.new(950, 5, 1))
		StatusService.Register(attacker)
		CombatService.Register(attacker, nil, "Fist")

		CombatService.AttackStart(attacker)
		CombatService.AttackCancel(attacker)
		expect(results, "CombatService: AttackCancel inside the cancel window ends the attack", attacker:GetAttribute("Attacking") == false)

		-- Fist's cancelInto is "Any": free to act again immediately, no
		-- extra cooldown - clearAttack always uses a 0 delay on a cancel.
		local restarted = CombatService.AttackStart(attacker)
		expect(
			results,
			"CombatService: cancelInto \"Any\" lets the attacker restart immediately, no recovery",
			restarted == true and attacker:GetAttribute("Attacking") == true
		)

		StatusService.Unregister(attacker)
		CombatService.Unregister(attacker)
		attacker:Destroy()
	end

	do
		local attacker = buildFakeCombatant("SelfTestCancelWindowAttacker", Vector3.new(970, 5, 0), Vector3.new(970, 5, 1))
		StatusService.Register(attacker)
		CombatService.Register(attacker, nil, "Fist")

		local tolerance = Config.Combat.HitTolerance

		CombatService.AttackStart(attacker)
		task.wait(fist.chain[1].cancelUntil + tolerance + 0.3) -- run well past hit 1's own cancelUntil
		CombatService.AttackCancel(attacker)
		expect(
			results,
			"CombatService: AttackCancel after the next unlanded hit's own cancelUntil is rejected",
			attacker:GetAttribute("Attacking") == true
		)

		StatusService.Unregister(attacker)
		CombatService.Unregister(attacker)
		attacker:Destroy()
	end

	-- REVIEW-M3-FIX4-S H3: cancelling is free only before any hit in the
	-- chain has landed (the block right above this one). Cancelling AFTER a
	-- hit already landed costs the same cooldown a full chain would
	-- (NextAttackAt = startedAt + style.recovery + chain[1].hitWindow.min),
	-- so "land hit 1, cancel, restart" can't out-DPS a full chain.
	do
		local attacker = buildFakeCombatant("SelfTestCancelAfterHitAttacker", Vector3.new(980, 5, 0), Vector3.new(980, 5, 1))
		StatusService.Register(attacker)
		CombatService.Register(attacker, nil, "Fist")

		local startedAt = Workspace:GetServerTimeNow()
		CombatService.AttackStart(attacker)

		local function waitUntilElapsed(targetElapsed: number)
			local remaining = targetElapsed - (Workspace:GetServerTimeNow() - startedAt)
			if remaining > 0 then
				task.wait(remaining)
			end
		end

		waitUntilElapsed((fist.chain[1].hitWindow.min + fist.chain[1].hitWindow.max) / 2)
		CombatService.AttackHit(attacker, 1) -- lands, nextHit becomes 2

		CombatService.AttackCancel(attacker) -- still well inside hit 2's own cancelUntil
		expect(results, "CombatService: AttackCancel after hit 1 landed still ends the attack", attacker:GetAttribute("Attacking") == false)

		local restartedTooSoon = CombatService.AttackStart(attacker)
		expect(
			results,
			"CombatService: cancelling after a landed hit is NOT free - an immediate restart is rejected (on cooldown)",
			restartedTooSoon == false
		)

		waitUntilElapsed(fist.recovery + fist.chain[1].hitWindow.min + Config.Combat.HitTolerance + 0.1)
		local restartedAfterCooldown = CombatService.AttackStart(attacker)
		expect(results, "CombatService: once that cooldown passes, the attacker can restart normally", restartedAfterCooldown == true)

		StatusService.Unregister(attacker)
		CombatService.Unregister(attacker)
		attacker:Destroy()
	end

	-- M3-FIX4-S rule 1/2: a Light "cannot be interrupted [by another
	-- Light]"; a Heavy always can - via the kind-conditional check in
	-- ApplyHit while the TARGET's own next unlanded hit is a Heavy, OR
	-- (REVIEW-M3-FIX4-S M2, confirmed intended) via the ordinary Stun path
	-- whenever a HEAVY lands on them, whatever they were doing - heavy stun
	-- overrides even a Light in progress.
	do
		local attacker = buildFakeCombatant("SelfTestInterruptLightAttacker", Vector3.new(1000, 5, 0), Vector3.new(1000, 5, 3))
		local target = buildFakeCombatant("SelfTestInterruptLightTarget", Vector3.new(1000, 5, 3), Vector3.new(1000, 5, 0))
		StatusService.Register(attacker)
		StatusService.Register(target)
		CombatService.Register(attacker, nil, "Fist")
		CombatService.Register(target, nil, "Fist")

		CombatService.AttackStart(target)
		expect(results, "CombatService: interrupt setup - the target's next unlanded hit is a Light", target:GetAttribute("Attacking") == true)

		CombatService.ApplyHit(attacker, target, fist, fist.chain[1], 1)
		expect(
			results,
			"CombatService: a Light can't be interrupted - getting hit while the next unlanded hit is Light leaves the attack running",
			target:GetAttribute("Attacking") == true
		)

		StatusService.Unregister(attacker)
		StatusService.Unregister(target)
		CombatService.Unregister(attacker)
		CombatService.Unregister(target)
		attacker:Destroy()
		target:Destroy()
	end

	-- REVIEW-M3-FIX4-S M2: unlike the Light-on-Light case right above, a
	-- landed HEAVY interrupts a target's Light in progress too - not
	-- through the kind-conditional check (which only fires for the
	-- target's own pending Heavy), but through the ordinary Stun-turns-on
	-- path (every Heavy applies a real Stun). That path is a deferred
	-- BindableEvent (StatusService.Changed), so this polls for it instead
	-- of asserting immediately (BUG-26's own fix pattern) - unlike the
	-- kind-conditional check, which runs synchronously inside ApplyHit
	-- itself and needs no poll.
	do
		local attacker = buildFakeCombatant("SelfTestInterruptHeavyOnLightAttacker", Vector3.new(1010, 5, 0), Vector3.new(1010, 5, 3))
		local target = buildFakeCombatant("SelfTestInterruptHeavyOnLightTarget", Vector3.new(1010, 5, 3), Vector3.new(1010, 5, 0))
		StatusService.Register(attacker)
		StatusService.Register(target)
		CombatService.Register(attacker, nil, "Fist")
		CombatService.Register(target, nil, "Fist")

		CombatService.AttackStart(target)
		expect(results, "CombatService: interrupt setup - the target's next unlanded hit is a Light", target:GetAttribute("Attacking") == true)

		CombatService.ApplyHit(attacker, target, fist, fist.chain[2], 2) -- a Heavy landing
		local interrupted = pollUntil(1, function()
			return target:GetAttribute("Attacking") == false
		end)
		expect(
			results,
			"CombatService: a landed Heavy interrupts a target's Light in progress too (heavy stun overrides)",
			interrupted
		)

		StatusService.Unregister(attacker)
		StatusService.Unregister(target)
		CombatService.Unregister(attacker)
		CombatService.Unregister(target)
		attacker:Destroy()
		target:Destroy()
	end

	do
		local attacker = buildFakeCombatant("SelfTestInterruptHeavyAttacker", Vector3.new(1020, 5, 0), Vector3.new(1020, 5, 3))
		local target = buildFakeCombatant("SelfTestInterruptHeavyTarget", Vector3.new(1020, 5, 3), Vector3.new(1020, 5, 0))
		StatusService.Register(attacker)
		StatusService.Register(target)
		CombatService.Register(attacker, nil, "Fist")
		CombatService.Register(target, nil, "Fist")

		local startedAt = Workspace:GetServerTimeNow()
		CombatService.AttackStart(target)
		local remaining = (fist.chain[1].hitWindow.min + fist.chain[1].hitWindow.max) / 2 - (Workspace:GetServerTimeNow() - startedAt)
		if remaining > 0 then
			task.wait(remaining)
		end
		CombatService.AttackHit(target, 1) -- lands (or whiffs - either way advances to hit 2, the Heavy)
		expect(results, "CombatService: interrupt setup - the target's next unlanded hit is now the Heavy", target:GetAttribute("Attacking") == true)

		CombatService.ApplyHit(attacker, target, fist, fist.chain[1], 1) -- any landed hit, light or heavy
		expect(
			results,
			"CombatService: getting hit while the next unlanded hit is a Heavy interrupts the attack",
			target:GetAttribute("Attacking") == false
		)

		StatusService.Unregister(attacker)
		StatusService.Unregister(target)
		CombatService.Unregister(attacker)
		CombatService.Unregister(target)
		attacker:Destroy()
		target:Destroy()
	end

	-- M3-FIX4-S rule 3/4: Dagger's cancelInto is "Jab" - a successful cancel
	-- immediately throws chain[1] as a new, feint-flagged attack; if THAT
	-- gets blocked (not parried), the attacker eats Recovery.
	do
		local attacker = buildFakeCombatant("SelfTestFeintAttacker", Vector3.new(1040, 5, 0), Vector3.new(1040, 5, 1))
		StatusService.Register(attacker)
		CombatService.Register(attacker, nil, "Dagger")

		CombatService.AttackStart(attacker)
		CombatService.AttackCancel(attacker)
		expect(
			results,
			"CombatService: cancelInto \"Jab\" immediately starts a new (feint) attack - Attacking stays true, not false",
			attacker:GetAttribute("Attacking") == true
		)

		StatusService.Unregister(attacker)
		CombatService.Unregister(attacker)
		attacker:Destroy()
	end

	-- REVIEW-M3-FIX4-S H2: a blocked feint doesn't just punish with Recovery -
	-- it ends the feinter's WHOLE chain outright, so a later chain hit can
	-- never sneak through once Recovery's own (short) duration runs out.
	-- Drives a REAL in-progress attack (AttackStart, not just a bare
	-- ApplyHit call) so entry.attack is genuinely live when the blocked hit
	-- resolves, exercising the actual clearAttack path.
	do
		local attacker = buildFakeCombatant("SelfTestFeintBlockedAttacker", Vector3.new(1060, 5, 0), Vector3.new(1060, 5, 1))
		local blocker = buildFakeCombatant("SelfTestFeintBlockedBlocker", Vector3.new(1060, 5, 2), Vector3.new(1060, 5, 0))
		HealthService.Register(blocker, { maxHealth = 100 })
		StatusService.Register(attacker)
		StatusService.Register(blocker)
		CombatService.Register(attacker, nil, "Dagger")
		CombatService.Register(blocker, nil, "Fist")

		local blockerHumanoid = blocker:FindFirstChildOfClass("Humanoid") :: Humanoid

		CombatService.AttackStart(attacker)
		expect(results, "CombatService: feint-block setup - the attacker has a real attack in progress", attacker:GetAttribute("Attacking") == true)

		-- Not parrying (past the parry window, still holding): resolves to
		-- a plain Blocked outcome, not a Parried one.
		StatusService.Apply(blocker, "Block", nil, { value = 0 })

		CombatService.ApplyHit(attacker, blocker, dagger, dagger.chain[1], 1, true) -- feint = true
		expect(
			results,
			"CombatService: a blocked (not parried) feint hit punishes the attacker with Recovery",
			StatusService.Has(attacker, "Recovery")
		)
		expect(
			results,
			"CombatService: a blocked feint ends the feinter's whole chain - Attacking clears immediately",
			attacker:GetAttribute("Attacking") == false
		)

		CombatService.AttackHit(attacker, 2) -- the chain's own hit 2, reported anyway
		expect(
			results,
			"CombatService: a hit-2 report after a blocked feint is dropped - there's no attack left to advance",
			blockerHumanoid.Health == 100 and attacker:GetAttribute("Attacking") == false
		)

		HealthService.Unregister(blocker)
		StatusService.Unregister(attacker)
		StatusService.Unregister(blocker)
		CombatService.Unregister(attacker)
		CombatService.Unregister(blocker)
		attacker:Destroy()
		blocker:Destroy()
	end

	-- M3-FIX4-S rule 6: HitCount +1 per landed hit from any source; the
	-- `everyHits`th (6th) hit knocks back and resets the count to 0.
	do
		local attacker = buildFakeCombatant("SelfTestHitCountAttacker", Vector3.new(1080, 5, 0), Vector3.new(1080, 5, 1))
		local target = buildFakeCombatant("SelfTestHitCountTarget", Vector3.new(1080, 5, 3), Vector3.new(1080, 5, 0))
		StatusService.Register(target)
		CombatService.Register(attacker, nil, "Fist")
		CombatService.Register(target, nil, "Fist")

		local jab = fist.chain[1]
		for i = 1, Combat.Knockback.everyHits - 1 do
			CombatService.ApplyHit(attacker, target, fist, jab, 1)
			expect(results, string.format("CombatService: HitCount is %d after %d landed hit(s)", i, i), target:GetAttribute("HitCount") == i)
		end

		CombatService.ApplyHit(attacker, target, fist, jab, 1) -- the 6th
		expect(
			results,
			"CombatService: HitCount resets to 0 once it reaches Combat.Knockback.everyHits (a knockback fired)",
			target:GetAttribute("HitCount") == 0
		)

		StatusService.Unregister(target)
		CombatService.Unregister(attacker)
		CombatService.Unregister(target)
		attacker:Destroy()
		target:Destroy()
	end

	-- M3-FIX4-S rule 7: Bleed stacks (refreshing, not extending, its own
	-- duration on a new stack) and HealthService ticks it once a second,
	-- floored at 1 HP so it never knocks out by itself.
	do
		local attacker = buildFakeCombatant("SelfTestBleedAttacker", Vector3.new(1100, 5, 0), Vector3.new(1100, 5, 1))
		local target = buildFakeCombatant("SelfTestBleedTarget", Vector3.new(1100, 5, 3), Vector3.new(1100, 5, 0))
		HealthService.Register(target, { maxHealth = 100 })
		StatusService.Register(attacker)
		StatusService.Register(target)
		CombatService.Register(attacker, nil, "Dagger")
		CombatService.Register(target, nil, "Dagger")
		local targetHumanoid = target:FindFirstChildOfClass("Humanoid") :: Humanoid

		local stab = dagger.chain[1] -- Light, bleedStacks = 1
		for i = 1, (dagger.bleed :: Combat.BleedTrait).maxStacks do
			CombatService.ApplyHit(attacker, target, dagger, stab, 1)
			expect(results, string.format("CombatService: Bleed stacks to %d", i), target:GetAttribute("Bleed") == i)
		end

		-- HealthService's own shared regen/bleed loop (Config.Health.Tick)
		-- does the actual ticking, not CombatService - 3 stacks x 1 dmg/s
		-- outpaces Idle's 2/s regen, net -1 HP/tick, so this reaches (and
		-- then holds at) the floor within a couple of real ticks.
		targetHumanoid.Health = 2
		local flooredAlive = pollUntil(4, function()
			return targetHumanoid.Health == 1
		end)
		expect(
			results,
			"HealthService: Bleed ticks damage and floors at 1 HP without knocking out",
			flooredAlive and targetHumanoid.Health > 0 and not StatusService.Has(target, "Knocked")
		)

		HealthService.Unregister(target)
		StatusService.Unregister(attacker)
		StatusService.Unregister(target)
		CombatService.Unregister(attacker)
		CombatService.Unregister(target)
		attacker:Destroy()
		target:Destroy()
	end

	-- M3-FIX4-S rule 1: LightStun blocks Block (and parry) but the target
	-- CAN still attack (and dash).
	do
		local attacker = buildFakeCombatant("SelfTestLightStunAttacker", Vector3.new(1120, 5, 0), Vector3.new(1120, 5, 1))
		local target = buildFakeCombatant("SelfTestLightStunTarget", Vector3.new(1120, 5, 3), Vector3.new(1120, 5, 0))
		StatusService.Register(attacker)
		StatusService.Register(target)
		CombatService.Register(attacker, nil, "Fist")
		CombatService.Register(target, nil, "Fist")

		CombatService.ApplyHit(attacker, target, fist, fist.chain[1], 1)
		expect(
			results,
			"CombatService: a landed Light applies LightStun",
			StatusService.Has(target, "LightStun") and target:GetAttribute("LightStunned") == true
		)

		CombatService.SetBlocking(target, true)
		expect(results, "CombatService: LightStun blocks starting a Block", not StatusService.Has(target, "Block"))

		local canStillAttack = CombatService.AttackStart(target)
		expect(
			results,
			"CombatService: LightStun does NOT block starting an attack (rule 1: light-stunned can still attack)",
			canStillAttack == true and target:GetAttribute("Attacking") == true
		)

		StatusService.Unregister(attacker)
		StatusService.Unregister(target)
		CombatService.Unregister(attacker)
		CombatService.Unregister(target)
		attacker:Destroy()
		target:Destroy()
	end

	-- CombatService.Attack (the NPC entry point) starts a swing and
	-- schedules every AttackHit report itself, at each hit's window
	-- midpoint - polled with a deadline (BUG-26's own fix pattern), not a
	-- fixed wait, since the scheduling itself uses task.delay.
	do
		local attacker = buildFakeCombatant("SelfTestNpcAttacker", Vector3.new(1150, 5, 0), Vector3.new(1150, 5, 1))
		local target = buildFakeCombatant("SelfTestNpcTarget", Vector3.new(1150, 5, 3), Vector3.new(1150, 5, 0))
		StatusService.Register(attacker)
		StatusService.Register(target)
		CombatService.Register(attacker, nil, "Fist")
		CombatService.Register(target, nil, "Fist")
		local targetHumanoid = target:FindFirstChildOfClass("Humanoid") :: Humanoid

		CombatService.Attack(attacker) -- the NPC entry point: schedules every hit itself

		local expectedDamage = fist.chain[1].damage + fist.chain[2].damage
		local lastWindow = fist.chain[#fist.chain].hitWindow
		local landedBoth = pollUntil(lastWindow.max + Config.Combat.HitTolerance + 0.5, function()
			return targetHumanoid.Health <= (100 - expectedDamage) and attacker:GetAttribute("Attacking") == false
		end)

		expect(results, "CombatService: the NPC sequence lands both chain hits on a fake target", landedBoth)

		StatusService.Unregister(attacker)
		StatusService.Unregister(target)
		CombatService.Unregister(attacker)
		CombatService.Unregister(target)
		attacker:Destroy()
		target:Destroy()
	end

	-- REVIEW-M5C-01 M5: HitLanded fires for EVERY landed hit, Light or
	-- Heavy alike - unlike the bridged `Hit` status (Heavy-only,
	-- M3-FIX4-S), which is what let a Light-hit courier through untouched
	-- against FragilePackage/VIP before this signal existed.
	do
		local attacker = buildFakeCombatant("SelfTestHitLandedAttacker", Vector3.new(1200, 5, 0), Vector3.new(1200, 5, 3))
		local target = buildFakeCombatant("SelfTestHitLandedTarget", Vector3.new(1200, 5, 3), Vector3.new(1200, 5, 0))
		StatusService.Register(attacker)
		StatusService.Register(target)
		CombatService.Register(attacker, nil, "Fist")
		CombatService.Register(target, nil, "Fist")

		local landed: { string } = {}
		local conn = CombatService.HitLanded:Connect(function(hitTarget: Model, _hitAttacker: Model, kind: string)
			if hitTarget == target then
				table.insert(landed, kind)
			end
		end)

		CombatService.ApplyHit(attacker, target, fist, fist.chain[1], 1) -- Light
		local sawLight = pollUntil(1, function()
			return #landed >= 1
		end)
		CombatService.ApplyHit(attacker, target, fist, fist.chain[2], 2) -- Heavy
		local sawBoth = pollUntil(1, function()
			return #landed >= 2
		end)

		conn:Disconnect()
		expect(results, "CombatService: HitLanded fires for a landed Light hit (not just Heavy - REVIEW-M5C-01 M5)", sawLight and landed[1] == "Light")
		expect(results, "CombatService: HitLanded fires for a landed Heavy hit too", sawBoth and landed[2] == "Heavy")

		StatusService.Unregister(attacker)
		StatusService.Unregister(target)
		CombatService.Unregister(attacker)
		CombatService.Unregister(target)
		attacker:Destroy()
		target:Destroy()
	end

	scratch:Destroy()
end

-- M3B-01: the combat stance - SetStance gating (locked/knocked), AttackStart
-- rejected outside the stance, and the tool -> style mapping.
local function testCombatStance(results: { Check })
	local scratch = Instance.new("Folder")
	scratch.Name = "SelfTestCombatStance"
	scratch.Parent = Workspace

	local function buildFakeCombatant(name: string, position: Vector3, lookAt: Vector3): Model
		local model = Instance.new("Model")
		model.Name = name
		local hrp = Instance.new("Part")
		hrp.Name = "HumanoidRootPart"
		hrp.Size = Vector3.new(2, 2, 1)
		hrp.Anchored = true
		hrp.CanCollide = false
		hrp.CFrame = CFrame.new(position, lookAt)
		hrp.Parent = model
		local humanoid = Instance.new("Humanoid")
		humanoid.MaxHealth = 100
		humanoid.Health = 100
		humanoid.Parent = model
		model.Parent = scratch
		return model
	end

	do
		local fakePlayerInstance = Instance.new("Folder")
		fakePlayerInstance.Name = "SelfTestStancePlayer"
		fakePlayerInstance.Parent = scratch
		local fakePlayer = (fakePlayerInstance :: any) :: Player

		local character = buildFakeCombatant("SelfTestStanceAttacker", Vector3.new(1200, 5, 0), Vector3.new(1200, 5, 1))
		StatusService.Register(character)
		CombatService.Register(character, fakePlayer, "Fist")

		local startedLocked = CombatService.SetStance(character, true)
		expect(
			results,
			"CombatService: SetStance is rejected while combat is locked (CombatUnlocked not true)",
			startedLocked == false and character:GetAttribute("InCombat") ~= true
		)

		local startedOutsideStance = CombatService.AttackStart(character)
		expect(results, "CombatService: AttackStart is rejected outside the combat stance", startedOutsideStance == false)

		fakePlayer:SetAttribute("CombatUnlocked", true)
		local startedUnlocked = CombatService.SetStance(character, true)
		expect(
			results,
			"CombatService: SetStance succeeds once CombatUnlocked is true",
			startedUnlocked == true and character:GetAttribute("InCombat") == true
		)

		-- REVIEW-M3B-01 H1: still InCombat (from the SetStance(true) just
		-- above) when the knockout lands - onStatusChanged's Knocked branch
		-- has to be what drops it, not a caller remembering to leave first.
		StatusService.Apply(character, "Knocked", 5)
		expect(results, "CombatService: a knockout drops a player out of the combat stance on its own", character:GetAttribute("InCombat") ~= true)

		local startedKnocked = CombatService.SetStance(character, true)
		expect(
			results,
			"CombatService: SetStance is rejected while knocked",
			startedKnocked == false and character:GetAttribute("InCombat") ~= true
		)

		StatusService.Unregister(character)
		CombatService.Unregister(character)
		character:Destroy()
	end

	-- REVIEW-M3B-01 H1's own guard: an NPC (owner == nil) is always
	-- InCombat by design and a knockout must never touch that.
	do
		local character = buildFakeCombatant("SelfTestStanceNpc", Vector3.new(1210, 5, 0), Vector3.new(1210, 5, 1))
		StatusService.Register(character)
		CombatService.Register(character, nil, "Fist")
		character:SetAttribute("InCombat", true) -- NpcService's own job normally, not CombatService's

		StatusService.Apply(character, "Knocked", 5)
		expect(results, "CombatService: a knockout never drops an NPC out of InCombat", character:GetAttribute("InCombat") == true)

		StatusService.Unregister(character)
		CombatService.Unregister(character)
		character:Destroy()
	end

	do
		local character = buildFakeCombatant("SelfTestToolAttacker", Vector3.new(1220, 5, 0), Vector3.new(1220, 5, 1))
		StatusService.Register(character)
		CombatService.Register(character, nil, "Fist")
		character:SetAttribute("InCombat", true) -- no stance gating needed for this check

		local tool = Instance.new("Tool")
		tool:SetAttribute("Weapon", "Dagger")
		tool.Parent = character
		local equipped = pollUntil(1, function()
			return character:GetAttribute("WeaponSet") == "Dagger"
		end)
		expect(results, "CombatService: equipping a weapon Tool sets WeaponSet to its own style", equipped)

		CombatService.AttackStart(character)
		expect(results, "CombatService: tool-equip setup - an attack is in progress", character:GetAttribute("Attacking") == true)

		tool:Destroy() -- unequip
		local unequipped = pollUntil(1, function()
			return character:GetAttribute("WeaponSet") == "Fist" and character:GetAttribute("Attacking") == false
		end)
		expect(results, "CombatService: unequipping the weapon Tool drops the style to Fist and cancels the in-progress attack", unequipped)

		StatusService.Unregister(character)
		CombatService.Unregister(character)
		character:Destroy()
	end

	scratch:Destroy()
end

-- M3-04: BehaviorTree node semantics (Selector short-circuit, Sequence
-- failure, Running propagation, Cooldown), pure and self-contained - no
-- Roblox instances needed, just counters and canned statuses.
local function testBehaviorTree(results: { Check })
	local function counted(status: BehaviorTree.Status): (BehaviorTree.Node, () -> number)
		local calls = 0
		local node: BehaviorTree.Node = BehaviorTree.Action(function(_bb: any): BehaviorTree.Status
			calls += 1
			return status
		end)
		return node, function()
			return calls
		end
	end

	do
		local failing, failingCalls = counted("Failure")
		local succeeding, succeedingCalls = counted("Success")
		local untouched, untouchedCalls = counted("Success")
		local selector = BehaviorTree.Selector({ failing, succeeding, untouched })

		local status = selector.Tick({})
		expect(results, "BehaviorTree: Selector returns the first non-Failure status", status == "Success")
		expect(results, "BehaviorTree: Selector ticked the failing child", failingCalls() == 1)
		expect(results, "BehaviorTree: Selector ticked the succeeding child", succeedingCalls() == 1)
		expect(results, "BehaviorTree: Selector short-circuits before the untouched child", untouchedCalls() == 0)
	end

	do
		local succeeding, succeedingCalls = counted("Success")
		local failing, failingCalls = counted("Failure")
		local untouched, untouchedCalls = counted("Success")
		local sequence = BehaviorTree.Sequence({ succeeding, failing, untouched })

		local status = sequence.Tick({})
		expect(results, "BehaviorTree: Sequence returns the first non-Success status", status == "Failure")
		expect(results, "BehaviorTree: Sequence ticked the succeeding child", succeedingCalls() == 1)
		expect(results, "BehaviorTree: Sequence ticked the failing child", failingCalls() == 1)
		expect(results, "BehaviorTree: Sequence short-circuits before the untouched child", untouchedCalls() == 0)
	end

	do
		local running = counted("Running")
		local selector = BehaviorTree.Selector({ running })
		expect(results, "BehaviorTree: Selector propagates Running", selector.Tick({}) == "Running")

		local sequence = BehaviorTree.Sequence({ running })
		expect(results, "BehaviorTree: Sequence propagates Running", sequence.Tick({}) == "Running")
	end

	do
		local succeeding, succeedingCalls = counted("Success")
		local gated = BehaviorTree.Cooldown(0.15, succeeding)

		expect(results, "BehaviorTree: Cooldown ticks its child the first time", gated.Tick({}) == "Success")
		expect(results, "BehaviorTree: Cooldown blocks a second tick immediately after", gated.Tick({}) == "Failure")
		expect(results, "BehaviorTree: Cooldown doesn't tick the child while gated", succeedingCalls() == 1)

		task.wait(0.2)
		expect(results, "BehaviorTree: Cooldown allows the child again once it elapses", gated.Tick({}) == "Success")
		expect(results, "BehaviorTree: Cooldown ticked the child a second time once ready", succeedingCalls() == 2)
	end
end

-- M3-04: the Target tree's give-up transition, driven with a fake
-- blackboard (a plain table, not even a real AiController) and fake
-- Model/Humanoid/HumanoidRootPart instances - StatusService.Has on an
-- unregistered character is just false, so "IsKnocked" never gets in the
-- way here.
local function testNpcService(results: { Check })
	local scratch = Instance.new("Folder")
	scratch.Name = "SelfTestNpcService"
	scratch.Parent = ServerStorage

	local function buildFakeNpc(name: string, position: Vector3): (Model, Humanoid, BasePart)
		local model = Instance.new("Model")
		model.Name = name
		local hrp = Instance.new("Part")
		hrp.Name = "HumanoidRootPart"
		hrp.Anchored = true
		hrp.CFrame = CFrame.new(position)
		hrp.Parent = model
		local humanoid = Instance.new("Humanoid")
		humanoid.MaxHealth = 100
		humanoid.Health = 100
		humanoid.Parent = model
		model.Parent = scratch
		return model, humanoid, hrp
	end

	do
		local attacker, attackerHumanoid, attackerRoot = buildFakeNpc("SelfTestNpcAttacker", Vector3.new(0, 0, 0))
		local farTarget = buildFakeNpc("SelfTestNpcFarTarget", Vector3.new(1000, 0, 0))

		local blackboard: { target: Model?, [string]: any } = {
			character = attacker,
			humanoid = attackerHumanoid,
			rootPart = attackerRoot,
			npcType = "Target",
			home = Vector3.new(0, 0, 0),
			target = farTarget :: Model?,
			wanderGoal = nil,
			path = nil,
			waypoints = nil,
			waypointIndex = 1,
			pathComputedAt = nil,
		}

		local tree = NpcTrees.BuildTarget()
		tree.Tick(blackboard)

		expect(results, "NpcService: the Target tree gives up on a target beyond GiveUpRadius", blackboard.target == nil)
	end

	do
		expect(results, "NpcService: ResolveNpcType defaults to Dummy", NpcService.ResolveNpcType(Instance.new("Model")) == "Dummy")
	end

	scratch:Destroy()
end

-- M3B-02: each trainer tree ticks without error through its main branch,
-- against a real registered trainer (so CombatService.Attack/AttackCancel/
-- SetBlocking and MovementService.Dash have live state to act on) and a
-- plain fake target Model whose Attacking/CurrentHit attributes are set
-- directly (a trainer only ever reads those two off its target, so there's
-- nothing for the target to be registered with).
local function testTrainers(results: { Check })
	local scratch = Instance.new("Folder")
	scratch.Name = "SelfTestTrainers"
	scratch.Parent = Workspace

	local function buildFakeCombatant(name: string, position: Vector3, lookAt: Vector3): Model
		local model = Instance.new("Model")
		model.Name = name
		local hrp = Instance.new("Part")
		hrp.Name = "HumanoidRootPart"
		hrp.Size = Vector3.new(2, 2, 1)
		hrp.Anchored = true
		hrp.CanCollide = false
		hrp.CFrame = CFrame.new(position, lookAt)
		hrp.Parent = model
		local humanoid = Instance.new("Humanoid")
		humanoid.MaxHealth = 100
		humanoid.Health = 100
		humanoid.Parent = model
		model.Parent = scratch
		return model
	end

	local function buildTrainerBlackboard(trainer: Model, target: Model, engageRadius: number): any
		local humanoid = trainer:FindFirstChildOfClass("Humanoid") :: Humanoid
		local rootPart = trainer:FindFirstChild("HumanoidRootPart") :: BasePart
		return {
			character = trainer,
			humanoid = humanoid,
			rootPart = rootPart,
			npcType = "Dummy",
			home = rootPart.Position,
			target = target,
			wanderGoal = nil,
			path = nil,
			waypoints = nil,
			waypointIndex = 1,
			pathComputedAt = nil,
			engageRadius = engageRadius,
		}
	end

	local function registerTrainer(trainer: Model)
		StatusService.Register(trainer)
		MovementService.Register(trainer, nil)
		CombatService.Register(trainer, nil, "Fist")
		pcall(function()
			trainer:SetAttribute("InCombat", true) -- a live trainer is always in the stance, same as any NPC
		end)
	end

	local function teardown(trainer: Model, target: Model)
		StatusService.Unregister(trainer)
		MovementService.Unregister(trainer)
		CombatService.Unregister(trainer)
		trainer:Destroy()
		target:Destroy()
	end

	do
		local trainer = buildFakeCombatant("SelfTestSam", Vector3.new(2000, 5, 0), Vector3.new(2000, 5, 1))
		local target = buildFakeCombatant("SelfTestSamTarget", Vector3.new(2000, 5, 3), Vector3.new(2000, 5, 4))
		registerTrainer(trainer)
		local bb = buildTrainerBlackboard(trainer, target, 50)
		local tree = NpcTrees.BuildTrainer("StraightSam", { rhythmSeconds = 0.01, engageRadius = 50 })
		tree.Tick(bb)
		expect(results, "Trainers: Straight Sam throws on rhythm", trainer:GetAttribute("Attacking") == true)
		teardown(trainer, target)
	end

	do
		local trainer = buildFakeCombatant("SelfTestTariq", Vector3.new(2010, 5, 0), Vector3.new(2010, 5, 1))
		local target = buildFakeCombatant("SelfTestTariqTarget", Vector3.new(2010, 5, 3), Vector3.new(2010, 5, 4))
		registerTrainer(trainer)
		local bb = buildTrainerBlackboard(trainer, target, 50)
		local tree = NpcTrees.BuildTrainer("TurtleTariq", { engageRadius = 50 })
		tree.Tick(bb)
		expect(results, "Trainers: Turtle Tariq blocks", StatusService.Has(trainer, "Block"))
		teardown(trainer, target)
	end

	do
		local trainer = buildFakeCombatant("SelfTestJamalIdle", Vector3.new(2020, 5, 0), Vector3.new(2020, 5, 1))
		local target = buildFakeCombatant("SelfTestJamalTargetIdle", Vector3.new(2020, 5, 3), Vector3.new(2020, 5, 4))
		target:SetAttribute("Attacking", false)
		target:SetAttribute("CurrentHit", "")
		registerTrainer(trainer)
		local bb = buildTrainerBlackboard(trainer, target, 50)
		local tree = NpcTrees.BuildTrainer("JabbingJamal", { reactionSeconds = 0.01, engageRadius = 50 })
		tree.Tick(bb)
		expect(
			results,
			"Trainers: Jabbing Jamal doesn't jab without a Heavy wind-up (blocks instead)",
			trainer:GetAttribute("Attacking") ~= true and StatusService.Has(trainer, "Block")
		)
		teardown(trainer, target)
	end

	do
		local trainer = buildFakeCombatant("SelfTestJamalReact", Vector3.new(2030, 5, 0), Vector3.new(2030, 5, 1))
		local target = buildFakeCombatant("SelfTestJamalTargetReact", Vector3.new(2030, 5, 3), Vector3.new(2030, 5, 4))
		target:SetAttribute("Attacking", true)
		target:SetAttribute("CurrentHit", "Heavy")
		registerTrainer(trainer)
		local bb = buildTrainerBlackboard(trainer, target, 50)
		local tree = NpcTrees.BuildTrainer("JabbingJamal", { reactionSeconds = 0.05, engageRadius = 50 })
		local jabbed = pollUntil(1, function()
			tree.Tick(bb)
			return trainer:GetAttribute("Attacking") == true
		end)
		expect(results, "Trainers: Jabbing Jamal jabs only when the target's CurrentHit == \"Heavy\"", jabbed)
		teardown(trainer, target)
	end

	do
		local trainer = buildFakeCombatant("SelfTestPeteLight", Vector3.new(2040, 5, 0), Vector3.new(2040, 5, 1))
		local target = buildFakeCombatant("SelfTestPeteTargetLight", Vector3.new(2040, 5, 3), Vector3.new(2040, 5, 4))
		target:SetAttribute("Attacking", true)
		target:SetAttribute("CurrentHit", "Light")
		registerTrainer(trainer)
		local bb = buildTrainerBlackboard(trainer, target, 50)
		local tree = NpcTrees.BuildTrainer("ParryPete", { reactionSeconds = 0.05, engageRadius = 50 })
		local parried = pollUntil(1, function()
			tree.Tick(bb)
			return StatusService.Has(trainer, "Block")
		end)
		expect(results, "Trainers: Parry Pete parries the target's first Light", parried)
		teardown(trainer, target)
	end

	do
		local trainer = buildFakeCombatant("SelfTestPeteHeavy", Vector3.new(2050, 5, 0), Vector3.new(2050, 5, 1))
		local target = buildFakeCombatant("SelfTestPeteTargetHeavy", Vector3.new(2050, 5, 3), Vector3.new(2050, 5, 4))
		target:SetAttribute("Attacking", true)
		target:SetAttribute("CurrentHit", "Heavy")
		registerTrainer(trainer)
		local bb = buildTrainerBlackboard(trainer, target, 50)
		local tree = NpcTrees.BuildTrainer("ParryPete", { reactionSeconds = 0.02, engageRadius = 50 })
		for _ = 1, 5 do
			tree.Tick(bb)
		end
		expect(results, "Trainers: Parry Pete never parries a Heavy", not StatusService.Has(trainer, "Block"))
		teardown(trainer, target)
	end

	do
		local trainer = buildFakeCombatant("SelfTestMohammed", Vector3.new(2060, 5, 0), Vector3.new(2060, 5, 1))
		local target = buildFakeCombatant("SelfTestMohammedTarget", Vector3.new(2060, 5, 3), Vector3.new(2060, 5, 4))
		registerTrainer(trainer)
		local bb = buildTrainerBlackboard(trainer, target, 50)
		local tree = NpcTrees.BuildTrainer("FeintingMohammed", { rhythmSeconds = 0.01, engageRadius = 50 })
		tree.Tick(bb)
		expect(results, "Trainers: Feinting Mohammed throws its light-heavy chain", trainer:GetAttribute("Attacking") == true)

		-- Combat.Styles.Fist.chain[2] (Heavy)'s own cancelUntil is 1.05s;
		-- its hitWindow doesn't open until 1.45s - a cancel caught well
		-- before that proves it didn't just land normally.
		local cancelled = pollUntil(1.3, function()
			tree.Tick(bb)
			return trainer:GetAttribute("Attacking") == false
		end)
		expect(results, "Trainers: Feinting Mohammed cancels its own heavy at cancelUntil", cancelled)

		local rejabbed = pollUntil(0.5, function()
			tree.Tick(bb)
			return trainer:GetAttribute("Attacking") == true
		end)
		expect(results, "Trainers: Feinting Mohammed re-jabs right after cancelling", rejabbed)
		teardown(trainer, target)
	end

	do
		local trainer = buildFakeCombatant("SelfTestDalila", Vector3.new(2080, 5, 0), Vector3.new(2080, 5, 1))
		local target = buildFakeCombatant("SelfTestDalilaTarget", Vector3.new(2080, 5, 3), Vector3.new(2080, 5, 4))
		target:SetAttribute("Attacking", true)
		target:SetAttribute("CurrentHit", "Heavy")
		registerTrainer(trainer)
		local bb = buildTrainerBlackboard(trainer, target, 50)
		local tree = NpcTrees.BuildTrainer("DashingDalila", { reactionSeconds = 0.05, rhythmSeconds = 0.05, engageRadius = 50 })
		local dashed = pollUntil(1, function()
			tree.Tick(bb)
			local nextDashAt = trainer:GetAttribute("NextDashAt")
			return typeof(nextDashAt) == "number" and (nextDashAt :: number) > 0
		end)
		expect(results, "Trainers: Dashing Dalila dashes away on the target's Heavy wind-up", dashed)
		teardown(trainer, target)
	end

	-- REVIEW-M3B-02: the non-reacting branch is a lone jab, not the full
	-- Sam-style chain - with the target idle, she should throw (Attacking
	-- true) and then self-cancel her own heavy (Attacking false again,
	-- well before the heavy's own hitWindow would resolve it naturally).
	do
		local trainer = buildFakeCombatant("SelfTestDalilaRhythm", Vector3.new(2085, 5, 0), Vector3.new(2085, 5, 1))
		local target = buildFakeCombatant("SelfTestDalilaRhythmTarget", Vector3.new(2085, 5, 3), Vector3.new(2085, 5, 4))
		target:SetAttribute("Attacking", false)
		target:SetAttribute("CurrentHit", "")
		registerTrainer(trainer)
		local bb = buildTrainerBlackboard(trainer, target, 50)
		local tree = NpcTrees.BuildTrainer("DashingDalila", { reactionSeconds = 0.05, rhythmSeconds = 0.01, engageRadius = 50 })

		local jabbed = pollUntil(1, function()
			tree.Tick(bb)
			return trainer:GetAttribute("Attacking") == true
		end)
		expect(results, "Trainers: Dashing Dalila jabs on rhythm when the target isn't winding up a Heavy", jabbed)

		local cancelled = pollUntil(1.3, function()
			tree.Tick(bb)
			return trainer:GetAttribute("Attacking") == false
		end)
		expect(results, "Trainers: Dashing Dalila cancels her own heavy - a lone jab, never the full chain", cancelled)

		teardown(trainer, target)
	end

	do
		expect(results, "Trees.WeightedPick: a single 100% option always wins", NpcTrees.WeightedPick({ throw = 1, cancel = 0, parry = 0, dash = 0 }, 0.5) == "throw")
		expect(results, "Trees.WeightedPick: picks the option the roll actually falls into", NpcTrees.WeightedPick({ throw = 0, cancel = 1, parry = 0, dash = 0 }, 0.999) == "cancel")
		expect(
			results,
			"Trees.WeightedPick: falls back to the first action when every weight is 0",
			NpcTrees.WeightedPick({ throw = 0, cancel = 0, parry = 0, dash = 0 }, 0.5) == "throw"
		)
	end

	do
		local trainer = buildFakeCombatant("SelfTestSinbad", Vector3.new(2090, 5, 0), Vector3.new(2090, 5, 1))
		local target = buildFakeCombatant("SelfTestSinbadTarget", Vector3.new(2090, 5, 3), Vector3.new(2090, 5, 4))
		registerTrainer(trainer)
		local bb = buildTrainerBlackboard(trainer, target, 50)
		local tree = NpcTrees.BuildTrainer("SparringSinbad", { rhythmSeconds = 0.01, engageRadius = 50, weights = { throw = 1, cancel = 0, parry = 0, dash = 0 } })
		tree.Tick(bb)
		expect(results, "Trainers: Sparring Sinbad picks by weights (100% throw always throws)", trainer:GetAttribute("Attacking") == true)
		teardown(trainer, target)
	end

	scratch:Destroy()
end

-- M3B-05: LifeService.HandleDeath's own branch logic (a live Humanoid.Died
-- round-trip needs a real Player - Player.Character/:LoadCharacter() aren't
-- fakeable the way DataService.ResetToTemplate's plain data table is, same
-- limitation as DataService.Wipe/.NewLife above).
local function testLifeService(results: { Check })
	do
		local data = ({ Character = { LivesLeft = 3 } } :: any) :: SaveSchema.Data
		local outcome = LifeService.HandleDeath(data)
		expect(
			results,
			"LifeService: a death with lives left just respawns the same character, no scene",
			outcome == "respawn" and data.Character.LivesLeft == 2
		)
	end

	do
		local data = ({ Character = { LivesLeft = 1 } } :: any) :: SaveSchema.Data
		local outcome = LifeService.HandleDeath(data)
		expect(
			results,
			"LifeService: the death that takes the last life runs the afterlife scene",
			outcome == "lastLife" and data.Character.LivesLeft == 0
		)
	end

	do
		expect(
			results,
			"SaveSchema: a fresh template starts with a full Character.LivesLeft",
			SaveSchema.Template.Character.LivesLeft == Config.Life.LivesPerCharacter
		)
	end

	-- REVIEW-M3B-05 M2(a): a combat knockout never reaches Humanoid.Died in
	-- the first place - CombatService.ApplyHit floors a lethal hit at 1 HP
	-- and applies Knocked instead of ever letting Health hit 0, so
	-- LifeService.onDied is never even invoked. No Player/DataService is
	-- involved in this scratch rig at all, which is itself the point: this
	-- combat path has no LivesLeft to touch.
	do
		local attacker = Instance.new("Model")
		attacker.Name = "SelfTestLifeKnockoutAttacker"
		local attackerHrp = Instance.new("Part")
		attackerHrp.Name = "HumanoidRootPart"
		attackerHrp.Anchored = true
		attackerHrp.CFrame = CFrame.new(Vector3.new(2100, 5, 0), Vector3.new(2100, 5, 1))
		attackerHrp.Parent = attacker
		attacker.Parent = Workspace

		local target = Instance.new("Model")
		target.Name = "SelfTestLifeKnockoutTarget"
		local targetHrp = Instance.new("Part")
		targetHrp.Name = "HumanoidRootPart"
		targetHrp.Anchored = true
		targetHrp.CFrame = CFrame.new(Vector3.new(2100, 5, 3), Vector3.new(2100, 5, 0))
		targetHrp.Parent = target
		local targetHumanoid = Instance.new("Humanoid")
		targetHumanoid.MaxHealth = 100
		targetHumanoid.Health = 3 -- less than the Jab's damage
		targetHumanoid.Parent = target
		target.Parent = Workspace

		StatusService.Register(target)

		local fist = Combat.styleFor("Fist") :: Combat.Style
		CombatService.ApplyHit(attacker, target, fist, fist.chain[1], 1)

		expect(
			results,
			"LifeService: a lethal combat hit knocks out (Health 1, Knocked) instead of reaching Humanoid.Died - LivesLeft is never in play",
			targetHumanoid.Health == 1 and StatusService.Has(target, "Knocked")
		)

		StatusService.Unregister(target)
		target:Destroy()
		attacker:Destroy()
	end

	-- REVIEW-M3B-05 M2(b): a fatal heart attack calls AgeService.
	-- StartDeathSequence with cause = "heartAttack" unconditionally (see
	-- AgeService.onBirthday/.ForceHeartAttack) - it never reads
	-- Character.LivesLeft at all, so it still wipes even with a full 4 left.
	-- DataService.NewLife's own reset pattern (capture Meta.Lives/keep the
	-- combat unlock, ResetToTemplate, restore them) is exactly what that
	-- path runs into.
	do
		local data = ({
			Version = Config.Data.SchemaVersion,
			Character = { LivesLeft = Config.Life.LivesPerCharacter },
			Meta = { Created = 222, LastSeen = 0, Lives = 2, Unlocks = { Combat = true } },
		} :: any) :: SaveSchema.Data
		local keepLives = data.Meta.Lives + 1
		local keepCreated = data.Meta.Created
		local keepCombatUnlocked = data.Meta.Unlocks.Combat

		DataService.ResetToTemplate(data)
		data.Meta.Lives = keepLives
		data.Meta.Created = keepCreated
		data.Meta.Unlocks.Combat = keepCombatUnlocked

		expect(
			results,
			"LifeService: a fatal heart attack with a full LivesLeft still wipes to a new character (Meta.Lives n -> n+1)",
			data.Meta.Lives == 3
		)
		expect(
			results,
			"LifeService: the new character from a heart attack starts with a full LivesLeft again",
			data.Character.LivesLeft == Config.Life.LivesPerCharacter
		)
	end
end

local function fakeMissionData(routes: { [string]: number }?, streak: number?, intercepted: number?): SaveSchema.Data
	return ({
		Bounty = 0,
		Progress = {
			Magoi = 0,
			GoldRukh = 0,
			BlackRukh = 0,
			Epithet = "",
			DeliveryStreak = streak or 0,
			Routes = routes or {},
			Intercepted = intercepted or 0,
		},
	} :: any) :: SaveSchema.Data
end

-- A canned nextRoll sequence for Cities.RollModifiers's self-test: returns
-- the queued values in order, so a modifier draw is fully deterministic
-- with no math.random involved.
local function cannedRolls(queue: { number }): (max: number) -> number
	local i = 0
	return function(_max: number): number
		i += 1
		return queue[i] :: number
	end
end

local function fakeMod(key: string, payMultiplier: number): Cities.ModifierRoll
	return { key = key, displayName = key, chance = 20, text = "", payMultiplier = payMultiplier }
end

-- M5C-01: delivery missions. Every check here is against the pure core
-- (Cities.RollModifiers/CombinedMultiplier, MissionService.FactorsFor/
-- BaseAmount/ComputePay/CurrentPay/TrySettle/MarkFailed/OnArrival/
-- CanIntercept/GetOrRoll/ApplySuccess/ApplyFailure/ApplyInterception/
-- IsOnRoute) - no Player, Instance or remote involved, same as every other
-- service's self-test in this file.
local function testMissionService(results: { Check })
	-- H7: route validation rejects an off-route city.
	expect(results, "MissionService: IsOnRoute accepts a real route destination", MissionService.IsOnRoute("Qarzin", "Saleh"))
	expect(results, "MissionService: IsOnRoute rejects a destination not on that city's route", not MissionService.IsOnRoute("Qarzin", "Rathole"))
	expect(results, "MissionService: IsOnRoute rejects an unknown city key entirely", not MissionService.IsOnRoute("Nope", "Qarzin"))

	-- The two old broken route names are fixed to real cities (never nil).
	expect(results, "Cities: Saleh's route no longer names the broken \"JADDATYSHUT\"", MissionService.IsOnRoute("Saleh", "JaddatysHut"))
	expect(results, "Cities: Rathole's route no longer names the broken \"CITYF\"", MissionService.IsOnRoute("Rathole", "Sahraqin"))

	-- REVIEW-M5C-01 H1: every real modifier's displayName is the old
	-- MissionDeliniation.Modifiers[*].Name, word for word - the client
	-- matches pop-outs (and Time Crunch/Courier Loop's own special cases)
	-- on this field, not the internal key.
	local expectedDisplayNames: { [string]: string } = {
		TimeCrunch = "Time Crunch",
		CourierLoop = "Courier Loop",
		HighlyValuable = "Highly Valuable",
		HeavyCargo = "Heavy Cargo",
		VIP = "Very Important Noble",
		FragilePackage = "Fragile Package",
		CleartheRoute = "Clear the Route",
	}
	for _, def in Cities.Modifiers do
		local expected = expectedDisplayNames[def.key]
		if expected then
			expect(results, string.format("Cities: %s's displayName matches the old GUI's title (\"%s\")", def.key, expected), def.displayName == expected)
		end
	end

	-- L15: payout formula with the old numbers - rank 1 (the dead "level"
	-- used to divide by zero here) no longer errors or blows up.
	do
		local pay = MissionService.ComputePay(1, 4, 0, {})
		expect(results, "MissionService: ComputePay at rank 1 doesn't divide by zero (AUDIT L15)", pay == math.floor(1 + 10 / 1 + 4 * 1.25 + 0 * 1.25))
	end
	do
		local withMods = MissionService.ComputePay(2, 10, 3, { fakeMod("TimeCrunch", 1.2) })
		local base = math.floor(1 + 10 / 2 + 10 * 1.25 + 3 * 1.25)
		expect(results, "MissionService: ComputePay applies the modifier multiplier on top of the base (AUDIT L14)", withMods == math.floor(base * 1.2))
	end

	-- Bryan's refinement: CurrentPay is ComputePay's live equivalent once
	-- some rolled modifiers may have failed mid-run - a failed one's own
	-- multiplier just drops out of the sum, everything else still counts.
	do
		local base = MissionService.BaseAmount(2, 10, 3)
		local modifiers = { fakeMod("TimeCrunch", 1.2), fakeMod("HeavyCargo", 1.3) }
		local allIntact = MissionService.CurrentPay(base, modifiers, {})
		expect(results, "MissionService: CurrentPay with nothing failed matches ComputePay", allIntact == MissionService.ComputePay(2, 10, 3, modifiers))

		-- M5/Bryan's refinement: a timer expiry or a landed hit against
		-- FragilePackage/VIP marks the modifier failed and drops its share
		-- of the payout - the run itself was never touched here at all
		-- (there's no run in this test, only the pure pay math).
		local timeCrunchFailed = MissionService.CurrentPay(base, modifiers, { TimeCrunch = true })
		expect(
			results,
			"MissionService (M5C-01 refinement): a failed modifier's multiplier drops out of CurrentPay, the rest still counts",
			timeCrunchFailed == math.floor(base * 1.3) and timeCrunchFailed < allIntact
		)

		local bothFailed = MissionService.CurrentPay(base, modifiers, { TimeCrunch = true, HeavyCargo = true })
		expect(results, "MissionService: every modifier failed leaves just the base amount", bothFailed == base)
	end

	-- M4: Clear the Route's bonus is conditional (earned a knockout during
	-- the run) - CurrentPay treats a not-yet-cleared CleartheRoute exactly
	-- like any other failed modifier once finishRun marks it so.
	do
		local base = MissionService.BaseAmount(1, 0, 0)
		local modifiers = { fakeMod("CleartheRoute", 1.5) }
		local cleared = MissionService.CurrentPay(base, modifiers, {})
		local notCleared = MissionService.CurrentPay(base, modifiers, { CleartheRoute = true })
		expect(results, "MissionService (M4): Clear the Route's multiplier only counts when credited", cleared == math.floor(base * 1.5) and notCleared == base)
	end

	-- Bryan's refinement: MarkFailed is idempotent - a caller fires the
	-- ModifierFailed update/log exactly once per modifier per run, even if
	-- the same trigger (e.g. several landed hits) fires repeatedly.
	do
		local failedKeys: { [string]: boolean } = {}
		expect(results, "MissionService: MarkFailed succeeds the first time", MissionService.MarkFailed(failedKeys, "FragilePackage"))
		expect(results, "MissionService: MarkFailed refuses a second time for the same key", not MissionService.MarkFailed(failedKeys, "FragilePackage"))
		expect(results, "MissionService: a different key still marks independently", MissionService.MarkFailed(failedKeys, "VIP"))
	end

	-- REVIEW-M5C-01B F3: every MissionUpdate carries the failed-keys SET as
	-- an array, so the client can re-grey them on any rebuild.
	do
		local failedKeys: { [string]: boolean } = { TimeCrunch = true, VIP = true }
		local list = MissionService.FailedKeysList(failedKeys)
		table.sort(list)
		expect(results, "MissionService (F3): FailedKeysList returns every failed key", #list == 2 and list[1] == "TimeCrunch" and list[2] == "VIP")
		expect(results, "MissionService (F3): FailedKeysList is empty when nothing has failed", #MissionService.FailedKeysList({}) == 0)
	end

	-- REVIEW-M5C-01B F4 (Bryan's call): the interceptor is paid the amount
	-- as it stood BEFORE the knocking blow's own Fragile/VIP reaction, and
	-- Clear the Route never counts for an interceptor at all.
	do
		local base = MissionService.BaseAmount(1, 0, 0)
		local modifiers = { fakeMod("VIP", 2), fakeMod("FragilePackage", 1.3) }

		-- The killing blow's own onHitLanded marks VIP/Fragile failed in
		-- `failedKeys`, but `preHitFailedKeys` (snapshotted just before that)
		-- is still empty - InterceptPay must use the snapshot, not the
		-- post-hit state, so the SAME hit that ends the run doesn't also
		-- cost the interceptor what it just failed for the courier.
		local postHitFailedKeys: { [string]: boolean } = { VIP = true, FragilePackage = true }
		local preHitFailedKeys: { [string]: boolean } = {}
		local intercepted = MissionService.InterceptPay(base, modifiers, preHitFailedKeys)
		expect(
			results,
			"MissionService (F4): the interceptor gets the pre-hit pay, not the post-hit (post-fail) pay",
			intercepted == MissionService.CurrentPay(base, modifiers, preHitFailedKeys)
				and intercepted > MissionService.CurrentPay(base, modifiers, postHitFailedKeys)
		)

		-- Clear the Route is force-excluded for an interceptor regardless of
		-- whether it happened to already be credited (the courier's own
		-- ApplySuccess/finishRun path is the only place it should ever pay).
		local withClearTheRoute = { fakeMod("CleartheRoute", 1.5) }
		local interceptedWithCtr = MissionService.InterceptPay(base, withClearTheRoute, {})
		expect(results, "MissionService (F4): Clear the Route never counts toward an interceptor's payout", interceptedWithCtr == base)
	end

	-- REVIEW-M5C-01B F5: the wire builder itself is pinned, not just the
	-- underlying data (H1's own fix) - `{key, name, chance, text}`, `name`
	-- is the DISPLAY name, `payMultiplier` never leaks onto the wire.
	do
		local wire = MissionService.WireModifiers({
			{ key = "TimeCrunch", displayName = "Time Crunch", chance = 20, text = "Complete in 3:00.", payMultiplier = 1.2 },
		})
		expect(results, "MissionService (F5): WireModifiers sends exactly one entry per modifier", #wire == 1)
		local entry = wire[1]
		expect(
			results,
			"MissionService (F5): WireModifiers pins {key, name, chance, text} - name is the display name, not the internal key",
			entry.key == "TimeCrunch" and entry.name == "Time Crunch" and entry.chance == 20 and entry.text == "Complete in 3:00." and entry.payMultiplier == nil
		)
	end

	-- The intercepted mark (Bryan): OfferMultiplier halves per stack with a
	-- 10% floor - 0.5, 0.25, floor at 0.1 once the halving would drop below
	-- it (0.5^4 = 0.0625).
	do
		expect(results, "MissionService (intercepted mark): 0 stacks is no reduction at all", MissionService.OfferMultiplier(0) == 1)
		expect(results, "MissionService (intercepted mark): 1 stack halves the offer", MissionService.OfferMultiplier(1) == 0.5)
		expect(results, "MissionService (intercepted mark): 2 stacks quarters it", MissionService.OfferMultiplier(2) == 0.25)
		expect(results, "MissionService (intercepted mark): 3 stacks is still above the floor (0.125)", math.abs(MissionService.OfferMultiplier(3) - 0.125) < 1e-9)
		expect(results, "MissionService (intercepted mark): 4+ stacks floors at 0.1, never reaches 0", MissionService.OfferMultiplier(4) == 0.1 and MissionService.OfferMultiplier(10) == 0.1)
	end

	-- ApplyOfferMultiplier/MarkIntercepted/ClearIntercepted: the pure pieces
	-- board offers, a courier's own reduced payout, and one delivery washing
	-- the mark away are all built from.
	do
		expect(results, "MissionService (intercepted mark): ApplyOfferMultiplier halves and floors", MissionService.ApplyOfferMultiplier(101, 0.5) == 50)
		expect(results, "MissionService (intercepted mark): ApplyOfferMultiplier at 1x changes nothing", MissionService.ApplyOfferMultiplier(101, 1) == 101)

		local data = fakeMissionData(nil, nil, 2)
		MissionService.MarkIntercepted(data)
		expect(results, "MissionService (intercepted mark): MarkIntercepted advances the stack by exactly one", data.Progress.Intercepted == 3)
		MissionService.ClearIntercepted(data)
		expect(results, "MissionService (intercepted mark): ClearIntercepted wipes every stack, not just decrements", data.Progress.Intercepted == 0)
	end

	-- Board offers are reduced the same way a courier's own finish payout
	-- is - both are BaseAmount/ComputePay combined with the SAME
	-- OfferMultiplier, so a marked player's board and their eventual payout
	-- never disagree.
	do
		local rankIndex, population, streak = 2, 10, 3
		local modifiers = { fakeMod("TimeCrunch", 1.2) }
		local base = MissionService.ComputePay(rankIndex, population, streak, modifiers)
		local oneStackOffer = MissionService.ApplyOfferMultiplier(base, MissionService.OfferMultiplier(1))
		local twoStackOffer = MissionService.ApplyOfferMultiplier(base, MissionService.OfferMultiplier(2))
		expect(results, "MissionService (intercepted mark): a marked player's board offer is half the unmarked one", oneStackOffer == math.floor(base * 0.5))
		expect(results, "MissionService (intercepted mark): two stacks quarters the offer, not just halves it again", twoStackOffer == math.floor(base * 0.25))
	end

	-- REVIEW-M5C-01C H1: the exact scenario the review found broken - open
	-- a board (cached), get intercepted on a DIFFERENT run, reopen the SAME
	-- board without it ever re-rolling: the cached destination must still
	-- show the new, reduced price (and a run started from it must carry
	-- the new offerMultiplier and withhold the interceptor's Black Rukh),
	-- because the fix stores NO multiplier in the cache at all - PreviewPay
	-- applies whatever `Progress.Intercepted` says right now, every call.
	do
		local cache: { [string]: any } = {}
		local modifiers = { fakeMod("HeavyCargo", 1.3) }
		local baseAmount = MissionService.BaseAmount(2, 0, 0)
		local rolls = 0
		local function roll()
			rolls += 1
			return { key = "Qarzin", modifiers = modifiers, baseAmount = baseAmount }
		end

		-- First open: 0 stacks, cached at "full price".
		local dest = MissionService.GetOrRoll(cache, "Qarzin", roll)
		local fullPrice = MissionService.PreviewPay(dest.baseAmount, dest.modifiers, MissionService.OfferMultiplier(0))
		expect(results, "MissionService (H1): the destination is rolled exactly once", rolls == 1)

		-- Simulate this player getting intercepted on a DIFFERENT run (their
		-- own stacks go 0 -> 1) - the cached entry for THIS destination is
		-- never touched, never re-rolled, never told about the mark.
		local stacksAfterInterception = 1

		-- Reopen the SAME board: GetOrRoll hits the cache (still 1 total
		-- roll), but PreviewPay must reflect the NEW multiplier.
		local destAgain = MissionService.GetOrRoll(cache, "Qarzin", roll)
		local halvedPrice = MissionService.PreviewPay(destAgain.baseAmount, destAgain.modifiers, MissionService.OfferMultiplier(stacksAfterInterception))
		expect(results, "MissionService (H1): reopening the board doesn't re-roll the cached destination", rolls == 1)
		expect(
			results,
			"MissionService (H1): a board reopened after an interception shows the HALVED price, not the stale full price",
			halvedPrice == math.floor(fullPrice * 0.5) and halvedPrice < fullPrice
		)

		-- Starting a run from that (still-cached) destination must carry
		-- the CURRENT multiplier, not the one that was in effect when it
		-- was first rolled.
		local runOfferMultiplier = MissionService.OfferMultiplier(stacksAfterInterception)
		expect(results, "MissionService (H1): a run started from the reopened board gets offerMultiplier 0.5, not 1.0", runOfferMultiplier == 0.5)
		local intercepted = MissionService.ApplyOfferMultiplier(MissionService.InterceptPay(destAgain.baseAmount, destAgain.modifiers, {}), runOfferMultiplier)
		expect(results, "MissionService (H1): intercepting a run from the reopened board pays the reduced amount", intercepted == halvedPrice)
		expect(results, "MissionService (H1): intercepting a run from the reopened board earns NO Black Rukh", not MissionService.InterceptorEarnsBlackRukh(runOfferMultiplier))

		-- A clearing delivery resets stacks to 0 - reopening again (same
		-- cache entry, still never re-rolled) must show full price again.
		local stacksAfterClearing = 0
		local destOnceMore = MissionService.GetOrRoll(cache, "Qarzin", roll)
		local fullPriceAgain = MissionService.PreviewPay(destOnceMore.baseAmount, destOnceMore.modifiers, MissionService.OfferMultiplier(stacksAfterClearing))
		expect(results, "MissionService (H1): still never re-rolled after all this", rolls == 1)
		expect(results, "MissionService (H1): after a clearing delivery, the reopened board is back to full price", fullPriceAgain == fullPrice)
	end

	-- The interceptor of an ALREADY-marked victim: reduced Copper (the same
	-- OfferMultiplier applied to their own InterceptPay) and no Black Rukh -
	-- but a FIRST-ever interception (0 stacks beforehand) still pays full
	-- price and a real Black Rukh.
	do
		local base = MissionService.BaseAmount(1, 0, 0)
		local modifiers = { fakeMod("HeavyCargo", 1.3) }
		local rawPayout = MissionService.InterceptPay(base, modifiers, {})

		local firstInterception = MissionService.ApplyOfferMultiplier(rawPayout, MissionService.OfferMultiplier(0))
		expect(results, "MissionService (intercepted mark): a courier's first-ever interception pays full price", firstInterception == rawPayout)
		expect(results, "MissionService (intercepted mark): a first-ever interception still earns the interceptor a Black Rukh", MissionService.InterceptorEarnsBlackRukh(MissionService.OfferMultiplier(0)))

		local secondInterception = MissionService.ApplyOfferMultiplier(rawPayout, MissionService.OfferMultiplier(1))
		expect(
			results,
			"MissionService (intercepted mark): intercepting an already-marked courier pays reduced Copper",
			secondInterception == math.floor(rawPayout * 0.5) and secondInterception < rawPayout
		)
		expect(
			results,
			"MissionService (intercepted mark): intercepting an already-marked courier earns NO Black Rukh",
			not MissionService.InterceptorEarnsBlackRukh(MissionService.OfferMultiplier(1))
		)
	end

	-- H2: the CourierLoop return leg sends "Started" with a phase change,
	-- never the old "Cleared" - REVIEW-M5C-01 H2, the client tears the
	-- whole run down on anything but "Started".
	do
		local nextPhase, state = MissionService.OnArrival("ToDestination", true)
		expect(results, "MissionService (H2): arriving with CourierLoop rolled switches to Returning", nextPhase == "Returning")
		expect(results, "MissionService (H2): the CourierLoop return leg sends \"Started\", never \"Cleared\"", state == "Started")

		local finishPhase, finishState = MissionService.OnArrival("ToDestination", false)
		expect(results, "MissionService: arriving with no CourierLoop means the run is done (finishRun)", finishPhase == nil and finishState == nil)

		local returningPhase = MissionService.OnArrival("Returning", true)
		expect(results, "MissionService: arriving back at the origin on the return leg means the run is done", returningPhase == nil)
	end

	-- M2 (lead decision, Bryan may change it): an interception only pays if
	-- the courier is genuinely out on the route - far enough from the
	-- origin OR far enough into the run - so two accounts can't farm the
	-- reward with no travel at all.
	do
		expect(results, "MissionService (M2): far enough from the origin counts as interceptable", MissionService.CanIntercept(Config.Missions.InterceptMinStuds, 0))
		expect(results, "MissionService (M2): far enough into the run counts even standing still", MissionService.CanIntercept(0, Config.Missions.InterceptMinSeconds))
		expect(
			results,
			"MissionService (M2): neither far enough nor long enough refuses the interception",
			not MissionService.CanIntercept(Config.Missions.InterceptMinStuds - 1, Config.Missions.InterceptMinSeconds - 1)
		)
	end

	-- M3: reopening the board reuses the same roll for a destination - the
	-- old MissionHandler's CityMods, ported - instead of re-rolling every
	-- time (which used to let a player fish for VIP/HighlyValuable).
	do
		local cache: { [string]: number } = {}
		local rolls = 0
		local function roll(): number
			rolls += 1
			return rolls
		end
		local first = MissionService.GetOrRoll(cache, "Qarzin", roll)
		local second = MissionService.GetOrRoll(cache, "Qarzin", roll)
		expect(results, "MissionService (M3): GetOrRoll only rolls once per key", rolls == 1)
		expect(results, "MissionService (M3): a cache hit returns the exact same value as the first roll", first == second)

		cache["Qarzin"] = nil -- simulates clearCachedRoll once a run to it starts
		local third = MissionService.GetOrRoll(cache, "Qarzin", roll)
		expect(results, "MissionService (M3): clearing the cache lets the next open roll fresh", rolls == 2 and third == 2)
	end

	-- AUDIT H8: a run settles (pays out/fails/is intercepted) exactly once.
	do
		local run = ({ settled = false } :: any) :: MissionService.SettleState
		expect(results, "MissionService: TrySettle succeeds the first time", MissionService.TrySettle(run))
		expect(results, "MissionService: TrySettle refuses a second time (paid exactly once)", not MissionService.TrySettle(run))
	end

	-- AUDIT M21: a real, persisted streak - success advances it and records
	-- route history; any failure (including an interception) resets it.
	do
		local data = fakeMissionData(nil, 2)
		MissionService.ApplySuccess(data, "Qarzin")
		expect(results, "MissionService: ApplySuccess advances the streak", data.Progress.DeliveryStreak == 3)
		expect(results, "MissionService: ApplySuccess records the destination in Routes", data.Progress.Routes["Qarzin"] == 1)
		MissionService.ApplySuccess(data, "Qarzin")
		expect(results, "MissionService: ApplySuccess accumulates Routes across repeat deliveries", data.Progress.Routes["Qarzin"] == 2)

		MissionService.ApplyFailure(data)
		expect(results, "MissionService: ApplyFailure resets the streak to 0", data.Progress.DeliveryStreak == 0)
		expect(results, "MissionService: ApplyFailure never touches Routes", data.Progress.Routes["Qarzin"] == 2)
	end

	-- AUDIT H8: interception pays the attacker's Bounty and never touches
	-- the courier's own save at all (nothing to farm back and forth).
	do
		local attackerData = fakeMissionData()
		local courierData = fakeMissionData(nil, 5)
		MissionService.ApplyInterception(attackerData, 42)
		MissionService.ApplyFailure(courierData)
		expect(results, "MissionService: ApplyInterception adds the reward to the attacker's Bounty", attackerData.Bounty == 42)
		expect(results, "MissionService: the courier's own Bounty is untouched by an interception", courierData.Bounty == 0)
		expect(results, "MissionService: the courier's streak still breaks on the interception (ApplyFailure)", courierData.Progress.DeliveryStreak == 0)
	end

	-- AUDIT M12: modifier roll weights respect route history and city
	-- safety - not a global counter nothing ever updated.
	do
		local inactive = fakeMissionData({ Qarzin = 3 })
		local active = fakeMissionData({ Qarzin = 20 })
		local factorsInactive = MissionService.FactorsFor(inactive, "Qarzin")
		local factorsActive = MissionService.FactorsFor(active, "Qarzin")
		expect(results, "MissionService: FactorsFor.PlayerActive is false below the threshold", not factorsInactive.PlayerActive)
		expect(results, "MissionService: FactorsFor.PlayerActive is true once the player has run the route enough", factorsActive.PlayerActive)
		expect(results, "MissionService: FactorsFor.SafeRoute follows Qarzin's own (Busy) safety rating", factorsActive.SafeRoute)

		local warTorn = MissionService.FactorsFor(fakeMissionData(), "Rathole")
		expect(results, "MissionService: FactorsFor.SafeRoute is false for a War-Torn city (Rathole)", not warTorn.SafeRoute)
	end

	-- Cities.RollModifiers: VIP/CleartheRoute only ever appear on an unsafe
	-- route (AUDIT M12 - reqs are checked for real now); HighlyValuable only
	-- on a safe one. A canned roll sequence makes every draw deterministic.
	do
		local safe = { PlayerActive = false, SafeRoute = true }
		local unsafe = { PlayerActive = false, SafeRoute = false }

		local eligibleSafe = Cities.EligiblePool(safe)
		local eligibleUnsafe = Cities.EligiblePool(unsafe)

		local function poolHas(pool: { Cities.ModifierDef }, key: string): boolean
			for _, def in pool do
				if def.key == key then
					return true
				end
			end
			return false
		end

		expect(results, "Cities: HighlyValuable is only eligible on a safe route", poolHas(eligibleSafe, "HighlyValuable") and not poolHas(eligibleUnsafe, "HighlyValuable"))
		expect(results, "Cities: VIP is only eligible on an unsafe route", poolHas(eligibleUnsafe, "VIP") and not poolHas(eligibleSafe, "VIP"))
		expect(results, "Cities: CleartheRoute is only eligible on an unsafe route", poolHas(eligibleUnsafe, "CleartheRoute") and not poolHas(eligibleSafe, "CleartheRoute"))
		expect(results, "Cities: TimeCrunch/HeavyCargo/FragilePackage have no reqs - eligible either way", poolHas(eligibleSafe, "TimeCrunch") and poolHas(eligibleUnsafe, "TimeCrunch"))

		-- Roll 1 in the (ordered) eligible pool always lands on its first
		-- entry (TimeCrunch, chance 20, cumulative 1-20); a gate roll of 6
		-- fails the "<= 5" 50% check for a second draw, so exactly one
		-- modifier comes back - fully deterministic, no math.random.
		local rolled = Cities.RollModifiers(unsafe, cannedRolls({ 1, 6 }))
		expect(results, "Cities: RollModifiers's first draw picks the lowest-cumulative eligible modifier for roll 1", #rolled == 1 and rolled[1].key == "TimeCrunch")

		-- A gate roll of 5 (<= 5) DOES pass, so a second draw happens; the
		-- next roll (11, past CourierLoop's cumulative 10 but within its
		-- own+CourierLoop's 13) lands on HeavyCargo. A second gate of 4
		-- (> 3) then stops it at exactly two modifiers.
		local rolledTwo = Cities.RollModifiers(unsafe, cannedRolls({ 1, 5, 11, 4 }))
		expect(
			results,
			"Cities: RollModifiers draws a second modifier when the 50% gate passes",
			#rolledTwo == 2 and rolledTwo[1].key == "TimeCrunch" and rolledTwo[2].key == "HeavyCargo"
		)
	end

	-- Cities.CombinedMultiplier: a bare mission (no modifiers) pays exactly
	-- the base amount; each modifier adds its own (payMultiplier - 1).
	expect(results, "Cities: CombinedMultiplier is 1 with no modifiers rolled", Cities.CombinedMultiplier({}) == 1)
	expect(
		results,
		"Cities: CombinedMultiplier stacks TimeCrunch (1.2) and HeavyCargo (1.3) additively (old citymodifier + 1)",
		math.abs(Cities.CombinedMultiplier({ fakeMod("TimeCrunch", 1.2), fakeMod("HeavyCargo", 1.3) }) - 1.5) < 1e-9
	)
end


local SelfTestService = {}

-- M6: the shared world clock's pure maths and the `.time` dev command, and
-- CollisionService's group assignment on a fake folder of parts.
local function testWorld(results: { Check })
	local D, N = Config.World.DayNight.DaySeconds, Config.World.DayNight.NightSeconds
	local L = D + N
	local function near(a: number, b: number): boolean
		return math.abs(a - b) < 0.01
	end
	expect(results, "WorldClock: day start reads 06:00", near(WorldClockService.ClockTimeAt(1000, 1000, L), 6))
	expect(results, "WorldClock: DaySeconds in reads 18:00", near(WorldClockService.ClockTimeAt(1000 + D, 1000, L), 18))
	expect(results, "WorldClock: mid-day reads 12:00", near(WorldClockService.ClockTimeAt(1000 + D / 2, 1000, L), 12))
	local midnight = WorldClockService.ClockTimeAt(1000 + D + N / 2, 1000, L)
	expect(results, "WorldClock: mid-night reads 00:00", math.min(midnight, 24 - midnight) < 0.01)
	expect(results, "WorldClock: end of the night wraps to 06:00", near(WorldClockService.ClockTimeAt(1000 + L, 1000, L), 6))
	expect(results, "WorldClock: a scaled day length keeps the ratio", near(WorldClockService.ClockTimeAt(1000 + D / 4, 1000, L / 2), 18))

	local fakePlayer = ({ Name = "SelfTestWorld", UserId = 27938432 } :: any) :: Player
	local wasPaused = WorldClockService.IsPaused()
	local oldHour = WorldClockService.CurrentHour()
	local oldSpeed = WorldClockService.GetSpeed()
	DevService.Dispatch(fakePlayer, ".time 20")
	expect(results, "WorldClock: .time 20 puts the clock at 20", near(WorldClockService.CurrentHour(), 20))
	DevService.Dispatch(fakePlayer, ".time pause")
	expect(results, "WorldClock: .time pause freezes the clock", WorldClockService.IsPaused() and near(WorldClockService.CurrentHour(), 20))
	DevService.Dispatch(fakePlayer, ".time 21")
	expect(results, "WorldClock: .time while paused moves the frozen hour", near(WorldClockService.CurrentHour(), 21))
	DevService.Dispatch(fakePlayer, ".time resume")
	expect(results, "WorldClock: .time resume unfreezes", not WorldClockService.IsPaused())
	DevService.Dispatch(fakePlayer, ".time speed 4")
	expect(results, "WorldClock: .time speed keeps the hour", near(WorldClockService.CurrentHour(), 21))
	expect(results, "WorldClock: .time speed 4 divides DayLength", near(Workspace:GetAttribute("DayLength") :: number, L / 4))
	DevService.Dispatch(fakePlayer, ".time speed 1")
	expect(results, "WorldClock: .time speed 1 restores DayLength", near(Workspace:GetAttribute("DayLength") :: number, L))
	local bad = DevService.Dispatch(fakePlayer, ".time 99")
	expect(results, "WorldClock: .time 99 is rejected", bad ~= nil and string.find(bad, "usage") ~= nil)
	-- Put the clock back where the test found it.
	WorldClockService.SetSpeed(oldSpeed)
	WorldClockService.SetHour(oldHour)
	if wasPaused then
		WorldClockService.Pause()
	end

	local root = Instance.new("Folder")
	local plain = Instance.new("Part")
	plain.Parent = root
	local union = Instance.new("UnionOperation")
	union.Parent = root
	local areas = Instance.new("Folder")
	areas.Name = "Areas"
	areas.Parent = root
	local areaPart = Instance.new("Part")
	areaPart.Parent = areas
	local rack = Instance.new("Model")
	rack.Name = "ClothingRack"
	rack.Parent = root
	local rackPart = Instance.new("Part")
	rackPart.Parent = rack
	local mapCount, rackCount = CollisionService.AssignTree(root)
	expect(results, "CollisionService: a plain part joins MapCollisionGroup", plain.CollisionGroup == "MapCollisionGroup")
	expect(results, "CollisionService: a Union joins MapCollisionGroup (L18)", union.CollisionGroup == "MapCollisionGroup")
	expect(results, "CollisionService: a part under Areas is left alone", areaPart.CollisionGroup == "Default")
	expect(results, "CollisionService: a rack part joins ClothingRackGroup", rackPart.CollisionGroup == "ClothingRackGroup")
	expect(results, "CollisionService: AssignTree counts 2 map, 1 rack", mapCount == 2 and rackCount == 1)
	root:Destroy()
end

function SelfTestService:Init() end

function SelfTestService:Start()
	if not Config.Debug.Enabled then
		return
	end

	local ok, results = pcall(function(): { Check }
		local collected: { Check } = {}
		testValidators(collected)
		testRemoteWrapper(collected)
		testDataService(collected)
		testPlayerService(collected)
		testDevService(collected)
		testData(collected)
		testCharacterService(collected)
		testAgeService(collected)
		testHealthService(collected)
		testRankService(collected)
		testEconomy(collected)
		testShop(collected)
		testItemService(collected)
		testShopService(collected)
		testStatusService(collected)
		testMovementService(collected)
		testCombatService(collected)
		testCombatStance(collected)
		testBehaviorTree(collected)
		testNpcService(collected)
		testTrainers(collected)
		testLifeService(collected)
		testMissionService(collected)
		testWorld(collected)
		return collected
	end)

	if not ok then
		log:Warn(string.format("FAIL: self-test errored: %s", tostring(results)))
		return
	end

	local failed: { string } = {}
	for _, check in results :: { Check } do
		if not check.pass then
			table.insert(failed, check.name)
		end
	end

	if #failed == 0 then
		log:Info(string.format("PASS (%d checks)", #(results :: { Check })))
	else
		log:Warn(string.format("FAIL (%d/%d): %s", #failed, #(results :: { Check }), table.concat(failed, "; ")))
	end
end

return SelfTestService
