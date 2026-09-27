--!strict
-- Runs quick, in-process checks of the shared core (Validate + the remote
-- wrapper) at Start, only when Config.Debug.Enabled. Never throws; logs one
-- PASS/FAIL summary line.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local Validate = require(ReplicatedStorage.Shared.Validate)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local SaveSchema = require(ReplicatedStorage.Shared.SaveSchema)
local LegacyBridge = require(script.Parent.LegacyBridge)
local PlayerService = require(script.Parent.PlayerService)
local DevService = require(script.Parent.DevService)
local Ranks = require(ReplicatedStorage.Shared.Data.Ranks)
local Alignment = require(ReplicatedStorage.Shared.Data.Alignment)
local Epithets = require(ReplicatedStorage.Shared.Data.Epithets)
local CharacterService = require(script.Parent.CharacterService)
local AgeService = require(script.Parent.AgeService)
local AgeHandler = require(script.Parent.AgeService.AgeHandler)

local log = Log.new("SelfTest")

type Check = { name: string, pass: boolean }
type RemoteDef = Remotes.RemoteDef

local function expect(results: { Check }, name: string, condition: boolean)
	table.insert(results, { name = name, pass = condition })
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

	for _, player in fakePlayers do
		Remotes.Server.ClearPlayerState(player)
	end
end

-- M1-03: a fake Data table exercises SaveSchema.Migrate's version bump, and
-- a temporary Folder stands in for a Player (LegacyBridge only needs an
-- Instance to parent the mirrored Values under; it never touches
-- Player-specific members).
local function testDataService(results: { Check })
	do
		local data = ({ Version = 0 } :: any) :: SaveSchema.Data
		SaveSchema.Migrate(data)
		expect(results, "SaveSchema: Migrate bumps Version to the current schema version", data.Version == Config.Data.SchemaVersion)
	end

	do
		local data: SaveSchema.Data = {
			Version = 1,
			Character = {
				FirstName = "Test",
				Gender = 1,
				Race = 2,
				Kingdom = 1,
				SkinTone = 1,
				HairColor = { R = 0.5, G = 0.5, B = 0.5 },
				EyeColor = 1,
				FaceBase = 1,
				MouthShape = 1,
				Height = 1,
				GrowthProfile = "",
			},
			Age = { Years = 13, TimePassed = 0, ProgToAge = 0 },
			Progress = { Magoi = 0, GoldRukh = 0, BlackRukh = 0, Epithet = "" },
			Bounty = 0,
			Economy = { Copper = 20, Silver = 0, Gold = 0 },
			Gear = { Shirt = "", Pants = "", Hats = { "", "", "" }, Inventory = {} },
			Family = {},
			Magic = {},
			Meta = { Created = 0, LastSeen = 0, Lives = 1 },
		}

		local standIn = Instance.new("Folder")
		local fakePlayer = (standIn :: any) :: Player

		local built = pcall(function()
			LegacyBridge.Build(fakePlayer, data)
		end)
		expect(results, "LegacyBridge: Build doesn't error", built)

		local firstNameValue: StringValue? = nil
		if built then
			local statsFolder = standIn:FindFirstChild("Stats")
			local child = statsFolder and statsFolder:FindFirstChild("FirstName")
			if child and child:IsA("StringValue") then
				firstNameValue = child
			end
		end
		expect(results, "LegacyBridge: Build creates Stats.FirstName", firstNameValue ~= nil)

		if firstNameValue then
			local value = firstNameValue :: StringValue
			expect(results, "LegacyBridge: Build pushes data onto the Value", value.Value == "Test")

			value.Value = "Changed"
			task.wait()
			expect(results, "LegacyBridge: a Value change writes back into data", data.Character.FirstName == "Changed")

			data.Character.FirstName = "FromData"
			LegacyBridge.Refresh(fakePlayer, data)
			expect(results, "LegacyBridge: Refresh pushes data back onto the Value", value.Value == "FromData")
		end

		if built then
			LegacyBridge.Destroy(fakePlayer)
		end
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
		},
		Age = { Years = 13, TimePassed = 0, ProgToAge = 0 },
		Progress = { Magoi = 0, GoldRukh = 0, BlackRukh = 0, Epithet = "" },
		Bounty = 0,
		Economy = { Copper = 20, Silver = 0, Gold = 0 },
		Gear = { Shirt = "", Pants = "", Hats = { "", "", "" }, Inventory = {} },
		Family = {},
		Magic = {},
		Meta = { Created = 0, LastSeen = 0, Lives = 1 },
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

local SelfTestService = {}

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
