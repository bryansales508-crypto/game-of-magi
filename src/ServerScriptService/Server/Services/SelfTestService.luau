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
