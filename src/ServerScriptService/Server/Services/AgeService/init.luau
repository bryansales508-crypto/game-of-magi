--!strict
-- Aging, visible aging and old-age death (TRIAGE #4, DESIGN.md section 3
-- "Aging while offline"/"Aging and death", Bryan's heart-attack styling in
-- docs/M2-PLAN.md). Replaces the old Character/AgeController.server.luau;
-- AgeHandler (growth maths) and HeightHandler (body resizing) move here
-- with it, ported to --!strict (FIX L5: hair follows the head's scale, not
-- the body's).
--
-- One shared server loop banks real seconds (times DevService.GetTimeScale)
-- for every loaded player into Age.ProgToAge and turns each
-- Config.Aging.SecondsPerYear into a birthday, instead of one thread per
-- player. Offline time ages a player up to Config.Aging.OfflineAgeCap (never
-- fatal) once, on load. From Config.Aging.DeathStart, every online birthday
-- fires HeartAttack; a fatal roll freezes the humanoid, waits for the
-- client's return-to-the-Rukh scene (or Config.Aging.SceneTimeout), then
-- starts a brand-new life.
--
-- M3B-05 (Bryan, 2026-09-28) added a second way to reach that same scene:
-- LifeService.luau's Character.LivesLeft running out on a real death
-- (falling, the void, drowning - never a combat knockout). The exported
-- AgeService.StartDeathSequence(player, data, cause) is the one function
-- both causes share; a fatal heart attack (cause = "heartAttack") is
-- unchanged, still firing its own richer HeartAttack remote itself before
-- calling in here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local SaveSchema = require(ReplicatedStorage.Shared.SaveSchema)
local ItemService = require(script.Parent.ItemService)
local DataService = require(script.Parent.DataService)
local PlayerService = require(script.Parent.PlayerService)
local DevService = require(script.Parent.DevService)
local AgeHandler = require(script.AgeHandler)
local HeightHandler = require(script.HeightHandler)

local log = Log.new("AgeService")

type Data = SaveSchema.Data

local SECONDS_PER_DAY = 86400

local AgeService = {}

-- ==================== pure helpers (self-tested directly) ====================

-- How many whole years to add for `daysAway` real days offline, capped so
-- a returning player is never aged past Config.Aging.OfflineAgeCap (offline
-- aging can never kill you).
function AgeService.OfflineAgingYears(currentYears: number, daysAway: number): number
	if daysAway <= 0 then
		return 0
	end
	local maxAdd = math.max(0, Config.Aging.OfflineAgeCap - currentYears)
	return math.min(math.floor(Config.Aging.OfflineYearsPerDay * daysAway), maxAdd)
end

-- Linear interpolation between Config.Aging.DeathChance's points; clamped
-- to the first/last point outside their range.
function AgeService.DeathChance(age: number): number
	local points = Config.Aging.DeathChance
	if age <= points[1][1] then
		return points[1][2]
	end
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		if age >= a[1] and age <= b[1] then
			local t = (age - a[1]) / (b[1] - a[1])
			return a[2] + t * (b[2] - a[2])
		end
	end
	return points[#points][2]
end

-- 0 before GreyStart, 1 at/after GreyEnd, linear between.
function AgeService.GreyFactor(age: number): number
	local start, finish = Config.Aging.GreyStart, Config.Aging.GreyEnd
	return math.clamp((age - start) / (finish - start), 0, 1)
end

-- R3: the applied (not saved) hair colour, lerped toward grey by age.
-- Called from CharacterService's build (every spawn) AND from onBirthday
-- below (so hair actually greys in on the birthday it's supposed to,
-- not only the next time the character happens to respawn).
local GREY_HAIR = Color3.fromRGB(200, 200, 200)

function AgeService.ApplyHairColor(character: Model, data: Data)
	local natural = Color3.new(data.Character.HairColor.R, data.Character.HairColor.G, data.Character.HairColor.B)
	local color = natural:Lerp(GREY_HAIR, AgeService.GreyFactor(data.Age.Years))
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") and part.Name:find("Handle") then
			part.Color = color
		end
	end
end

-- ==================== growth / resize ====================

-- Moved here from AppearanceController: the very first roll for a life,
-- whenever GrowthProfile is still "" (a new save, or right after NewLife).
local function rollFirstGrowth(data: Data)
	local profileStr, height = AgeHandler.start(data.Age.Years, data.Character.Race, data.Character.Gender)
	data.Character.GrowthProfile = profileStr
	data.Character.Height = height
end

-- Destroys and re-equips any currently-worn game hat/cloak so it fits the
-- new size (old AgeController.rebuildAccessories, now reading Gear.Hats
-- directly instead of the legacy OnCharacter.Hats Values).
local function rebuildAccessories(character: Model, data: Data)
	for _, accessory in character:GetChildren() do
		if accessory:IsA("Accessory") and HeightHandler.isGameHat(accessory.Name) then
			accessory:Destroy()
		end
	end
	for _, code in data.Gear.Hats do
		if code ~= "" then
			ItemService.Equip(code, character)
		end
	end
end

-- Resizes `player`'s current character to its save's growth profile at its
-- current age. Safe to call on every spawn and on every birthday (old
-- AgeController did both). Rolls a growth profile first if one is somehow
-- still missing (same defensive fallback the old sizeCharacter had).
local function resizeCharacter(player: Player, data: Data)
	local character = player.Character
	if character == nil then
		return
	end

	if AgeHandler.unpack(data.Character.GrowthProfile) == nil then
		rollFirstGrowth(data)
	end
	local profile = AgeHandler.unpack(data.Character.GrowthProfile)
	if profile == nil then
		log:Error(string.format("%s has no usable growth profile even after rolling one", player.Name))
		return
	end

	local height = AgeHandler.heightAt(profile, data.Age.Years)
	local fat = AgeHandler.fatAt(profile, data.Age.Years)
	local ratio = HeightHandler.heightToRatio(height, fat)

	HeightHandler.resize(character:GetDescendants(), ratio, character)
	rebuildAccessories(character, data)

	data.Character.Height = height
end

-- ==================== offline aging ====================

-- R6: `daysAway` is only ever turned into whole years (OfflineAgingYears
-- floors it), and TimePassed is then reset to now - so a fractional
-- leftover day is dropped, not banked. Intended: a player who reliably
-- rejoins every ~11h (say) never ages offline from that alone. This is
-- fine at the design's real scale (2 years/day; the shortfall is well
-- under a day even played daily for months) and deliberately NOT banked
-- into ProgToAge, which would count it at the much faster online rate.
local function applyOfflineAging(player: Player, data: Data)
	local daysAway = (os.time() - data.Age.TimePassed) / SECONDS_PER_DAY
	local add = AgeService.OfflineAgingYears(data.Age.Years, daysAway)
	if add > 0 then
		data.Age.Years += add
		log:Info(string.format("%s aged %d year(s) offline (%.1f day(s) away)", player.Name, add, daysAway))
	end
	data.Age.TimePassed = os.time()
end

-- ==================== online aging loop ====================

local active: { [Player]: boolean } = {}

local sceneDoneBindable = Instance.new("BindableEvent")

-- Suspends the calling thread until `player` fires RukhSceneDone, or
-- Config.Aging.SceneTimeout elapses. R7: NOT scaled by DevService.GetTimeScale
-- (unlike the online tick) - the client's scene takes about the same real
-- time to play regardless of aging speed, so scaling this down (e.g. to
-- 0.5s at .timescale 60) used to cut the scene off mid-playback during tests.
local function waitForRukhSceneDone(player: Player)
	local timeoutSeconds = Config.Aging.SceneTimeout
	local callingThread = coroutine.running()
	local settled = false
	local connection: RBXScriptConnection

	local function settle()
		if settled then
			return
		end
		settled = true
		connection:Disconnect()
		task.spawn(callingThread)
	end

	connection = sceneDoneBindable.Event:Connect(function(firedPlayer: Player)
		if firedPlayer == player then
			settle()
		end
	end)
	task.delay(timeoutSeconds, settle)

	coroutine.yield()
end

-- Freezes the humanoid, starts a completely fresh life right away, waits
-- for the scene (or its timeout), then respawns. Runs as its own task so
-- it never blocks the shared aging loop for every other player. Shared by
-- a fatal heart attack (cause = "heartAttack", the HeartAttack remote is
-- already fired by the caller before this runs - unchanged) and M3B-05's
-- last-life death (cause = "lastLife", the new Died remote is fired here -
-- LifeService.luau calls this directly for that path). Exported so
-- LifeService can reuse it without duplicating the freeze/NewLife/scene-
-- wait/respawn plumbing this file already owns (Dying, RukhSceneDone).
function AgeService.StartDeathSequence(player: Player, data: Data, cause: "heartAttack" | "lastLife")
	player:SetAttribute("Dying", true)

	if cause == "lastLife" then
		Remotes.Server.Fire("Died", player, { cause = "lastLife" })
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.JumpHeight = 0
	end
	-- M3B-01: the death scene isn't a state to keep fighting from - same
	-- direct-attribute pattern as the WalkSpeed/Jump freeze just above
	-- (CombatService owns InCombat, but this is the one moment old and new
	-- code alike already reach straight into a frozen character's own
	-- attributes rather than going through the service that normally owns
	-- them).
	if character then
		pcall(function()
			character:SetAttribute("InCombat", false)
		end)
	end

	-- R2: NewLife runs now, before the scene wait, not after - a player
	-- who leaves mid-scene (or during the timeout) then never keeps the
	-- old 60+ life; the save is already the fresh one no matter when they
	-- come back. F2's reasoning still applies to the fresh life: NewLife
	-- resets Character.Gender to 0 too, so it goes through
	-- CharacterService's wait-for-CreateCharacter path again, which rolls
	-- growth once gender is known - not eagerly here, gender-blind.
	DataService.NewLife(player)
	player:SetAttribute("Age", data.Age.Years)
	player:SetAttribute("Lives", data.Meta.Lives)
	-- M3B-05: LifeService owns LivesLeft conceptually, but NewLife already
	-- reset it (DataService.ResetToTemplate) by the time we're here, and
	-- this is the one place both death causes already refresh the sibling
	-- Lives attribute right after NewLife - simplest to mirror it alongside
	-- Lives rather than round-trip back through LifeService for this.
	pcall(function()
		player:SetAttribute("LivesLeft", data.Character.LivesLeft)
	end)

	waitForRukhSceneDone(player)

	if player.Parent ~= Players then
		return
	end

	player:SetAttribute("Dying", false)
	-- R1: without this, tickPlayer never picks this player up again this
	-- session (onBirthday cleared it before spawning this task) and the
	-- fresh life stays 13 forever, until they rejoin.
	active[player] = true

	player:LoadCharacter()
end

-- Applies one birthday: age up, resize, and (from DeathStart) roll a heart
-- attack. Returns true if this birthday was fatal (the caller must stop
-- processing any further banked years this tick: `data` now belongs to a
-- brand-new life once NewLife runs). R4: a no-op while already Dying, so a
-- forced birthday (or a stray tick) can't roll again mid-death-sequence.
local function onBirthday(player: Player, data: Data): boolean
	if player:GetAttribute("Dying") then
		return false
	end

	data.Age.Years += 1
	player:SetAttribute("Age", data.Age.Years)
	resizeCharacter(player, data)
	-- R3: greys in on the birthday it's actually due, not only whenever
	-- the character next happens to respawn.
	local character = player.Character
	if character then
		AgeService.ApplyHairColor(character, data)
	end

	if data.Age.Years < Config.Aging.DeathStart then
		return false
	end

	-- BUG-20 (Bryan, design): with mortality off (Studio default), the
	-- death roll is skipped entirely - not rolled-then-discarded - so dev
	-- aging (.age/.birthday, and natural aging while it's off) can never
	-- kill a test character; the non-fatal heartbeat/pulse still plays
	-- every birthday from DeathStart either way. `.heart fatal` bypasses
	-- this (ForceHeartAttack never calls onBirthday).
	local chance = AgeService.DeathChance(data.Age.Years)
	local fatal = DevService.IsMortal() and math.random() < chance
	Remotes.Server.Fire("HeartAttack", player, data.Age.Years, fatal)
	log:Info(
		string.format(
			"%s has a heart attack at age %d (fatal=%s, chance=%.2f, mortal=%s)",
			player.Name,
			data.Age.Years,
			tostring(fatal),
			chance,
			tostring(DevService.IsMortal())
		)
	)

	if not fatal then
		return false
	end

	active[player] = nil
	task.spawn(function()
		AgeService.StartDeathSequence(player, data, "heartAttack")
	end)
	return true
end

local function tickPlayer(player: Player, data: Data)
	local now = os.time()
	local elapsedReal = now - data.Age.TimePassed
	if elapsedReal <= 0 then
		return
	end
	data.Age.TimePassed = now
	data.Age.ProgToAge += elapsedReal * DevService.GetTimeScale()

	local yearsToAdd = math.floor(data.Age.ProgToAge / Config.Aging.SecondsPerYear)
	if yearsToAdd <= 0 then
		return
	end
	data.Age.ProgToAge -= yearsToAdd * Config.Aging.SecondsPerYear

	for _ = 1, yearsToAdd do
		if onBirthday(player, data) then
			return
		end
	end
end

-- Exposed for the .birthday/.heart dev commands (registered below). R4:
-- both refuse while Dying, so `.heart fatal` during a real death sequence
-- (or a repeat) can't start a second one - NewLife running twice would
-- double Meta.Lives and load the character twice. BUG-08: the reason a
-- refusal happened is returned too, so the dev command can say why
-- ("already dying") instead of the same generic failure as no-save-loaded.
function AgeService.ForceBirthday(player: Player): (boolean, string?)
	if player:GetAttribute("Dying") then
		return false, "already dying"
	end
	local data = DataService.Get(player)
	if data == nil then
		return false, "no save loaded"
	end
	onBirthday(player, data)
	return true, nil
end

function AgeService.ForceHeartAttack(player: Player, fatal: boolean): (boolean, string?)
	if player:GetAttribute("Dying") then
		return false, "already dying"
	end
	local data = DataService.Get(player)
	if data == nil then
		return false, "no save loaded"
	end
	Remotes.Server.Fire("HeartAttack", player, data.Age.Years, fatal)
	if fatal then
		active[player] = nil
		task.spawn(function()
			AgeService.StartDeathSequence(player, data, "heartAttack")
		end)
	end
	return true, nil
end

-- ==================== service ====================

function AgeService:Init()
	Remotes.Server.On("RukhSceneDone", function(player: Player)
		sceneDoneBindable:Fire(player)
	end)

	-- BUG-15: `.age`/`.age+` used to only change the number; resize and
	-- grey hair right away too instead of waiting for the next birthday.
	DevService.OnAgeChanged(function(player: Player, data: Data)
		-- BUG-17: this hook resized/greyed hair but never set the Age
		-- attribute itself, so the menu's age line stayed stale until the
		-- next birthday (onBirthday sets it directly; this path didn't).
		player:SetAttribute("Age", data.Age.Years)
		resizeCharacter(player, data)
		local character = player.Character
		if character then
			AgeService.ApplyHairColor(character, data)
		end
	end)

	-- Registered here (DevService.Register, not a direct require of
	-- AgeService from DevService) so DevService never has to require this
	-- service back: Roblox errors on a cyclic ModuleScript require, and
	-- AgeService already requires DevService for GetTimeScale.
	DevService.Register("birthday", "[player] - force one birthday tick now", function(caller: Player, args: { string })
		local target, err = DevService.ResolvePlayer(caller, args[1])
		if target == nil then
			return err or "player not found"
		end
		local ok, reason = AgeService.ForceBirthday(target)
		if not ok then
			return string.format("%s: %s", target.Name, reason or "failed")
		end
		local data = DataService.Get(target)
		return string.format("%s's birthday: now age %s", target.Name, if data then tostring(data.Age.Years) else "?")
	end)

	DevService.Register(
		"heart",
		'[fatal] [player] - fire a heart attack now; pass "fatal" first to make it lethal',
		function(caller: Player, args: { string })
			local fatal = false
			local rest = args
			if args[1] and args[1]:lower() == "fatal" then
				fatal = true
				rest = table.move(args, 2, #args, 1, {} :: { string })
			end
			local target, err = DevService.ResolvePlayer(caller, rest[1])
			if target == nil then
				return err or "player not found"
			end
			local ok, reason = AgeService.ForceHeartAttack(target, fatal)
			if not ok then
				return string.format("%s: %s", target.Name, reason or "failed")
			end
			return string.format("Heart attack fired for %s (fatal=%s)", target.Name, tostring(fatal))
		end
	)
end

function AgeService:Start()
	DataService.Loaded:Connect(function(player: Player)
		local data = DataService.Get(player)
		if data == nil then
			return
		end

		applyOfflineAging(player, data)
		-- REVIEW-M2-01 F2: the first growth-profile roll needs gender
		-- (totalGain is 0.9x for gender 2), which isn't chosen yet this
		-- early for a brand-new life - rolling here regardless used to
		-- always take the male curve. CharacterService now rolls it once
		-- gender is known; resizeCharacter's own fallback below still
		-- catches it defensively if that's ever skipped.
		player:SetAttribute("Age", data.Age.Years)

		active[player] = true
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		active[player] = nil
	end)

	-- Resize on every spawn (not just birthdays), same as the old
	-- AgeController's CheckSizing marker. Waits for CharacterService's
	-- AppearenceLoaded so hats/accessories exist before being re-fitted.
	PlayerService.Ready:Connect(function(player: Player, character: Model)
		task.spawn(function()
			local data = DataService.Get(player)
			if data == nil then
				return
			end

			-- R10: startDeathSequence only froze the character alive at the
			-- fatal roll; a character that spawns mid-scene (a reset, or
			-- any other stray respawn while Dying) used to be left free to
			-- move around before the scene actually finishes.
			if player:GetAttribute("Dying") then
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				if humanoid then
					humanoid.WalkSpeed = 0
					humanoid.JumpPower = 0
					humanoid.JumpHeight = 0
				end
			end

			local appearenceLoaded = character:WaitForChild("AppearenceLoaded", 30)
			if appearenceLoaded == nil or not appearenceLoaded:IsA("BoolValue") then
				return
			end
			if not appearenceLoaded.Value then
				appearenceLoaded.Changed:Wait()
			end
			if player.Parent ~= Players or player.Character ~= character then
				return
			end

			resizeCharacter(player, data)
		end)
	end)

	task.spawn(function()
		while true do
			task.wait(Config.Aging.Tick)
			for player in active do
				if player.Parent ~= Players then
					active[player] = nil
					continue
				end
				local data = DataService.Get(player)
				if data then
					tickPlayer(player, data)
				end
			end
		end
	end)
end

return AgeService
