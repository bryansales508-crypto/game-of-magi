--!strict
-- Delivery missions (M5-PLAN.md Phase 5C, Bryan's rules 2026-09-29). One
-- board per player, opened from a `*Delivery` part; a route/board
-- membership check on every start (fixes H7 - the old code trusted any city
-- name the client sent); modifiers rolled server-side from the player's own
-- route history and each city's Safety (fixes M12); one shared 0.5s loop for
-- arrivals, TimeCrunch and the beacon (fixes H9 - the old code left a
-- per-frame loop running forever per board click); an interception pays the
-- attacker instantly and exactly once (fixes H8); a real, saved success
-- streak (fixes M21); the old reward formula with the dead "level" replaced
-- by rank index (fixes L15's division by zero).
--
-- Ported from (now removed) SSS/MISC/MissionHandler/init.server.luau,
-- RS/Modules/MissionDeliniation.luau and RS/Modules/RewardHandler.luau; see
-- docs/SYSTEMS.md section 7 and docs/reference/m5c-studio-dump.md.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Config = require(ReplicatedStorage.Shared.Config)
local SaveSchema = require(ReplicatedStorage.Shared.SaveSchema)
local Cities = require(ReplicatedStorage.Shared.Data.Cities)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local RankService = require(script.Parent.RankService)
local MovementService = require(script.Parent.MovementService)
local StatusService = require(script.Parent.StatusService)
local DevService = require(script.Parent.DevService)

local log = Log.new("MissionService")

type Data = SaveSchema.Data
type ModifierRoll = Cities.ModifierRoll

local MissionService = {}

-- ==================== pure core (self-tested directly) ====================

-- Pure: whether `destinationKey` is actually on `cityKey`'s trade route
-- (fixes H7 - the old server never checked this at all). Used both as the
-- remote handler's real guard (on top of "is it on THIS board", which
-- already implies it, since a board is only ever built from a real route -
-- this is the defense-in-depth copy, and what the self-test exercises
-- directly) and by the dev `.mission start` command.
function MissionService.IsOnRoute(cityKey: string, destinationKey: string): boolean
	local route = Cities.Routes[cityKey]
	if route == nil then
		return false
	end
	for _, key in route do
		if key == destinationKey then
			return true
		end
	end
	return false
end

-- Pure: the roll factors for one destination, from the PLAYER's own save
-- (Progress.Routes - a real per-player count, AUDIT M12) and the
-- destination city's static Safety (Cities.luau, standing in for the old
-- global successRate counter nothing ever wrote to).
function MissionService.FactorsFor(data: Data, destinationKey: string): Cities.Factors
	local city = Cities.ByKey[destinationKey]
	local safety = if city then city.safety else 0
	local timesRun = data.Progress.Routes[destinationKey] or 0
	return {
		PlayerActive = timesRun > Config.Missions.PlayerActiveThreshold,
		SafeRoute = safety > Config.Missions.SafeRouteThreshold,
	}
end

-- Pure: the old RewardHandler.rewardcaculation formula (base + weaklingBonus
-- + population*1.25 + streak*1.25, floored), ported with two fixes:
-- `rankIndex` replaces the dead race-branched "level" (Ranks.rankFor never
-- returns less than 1, so 10/rankIndex can no longer divide by zero -
-- AUDIT L15), and `streak` is the real, saved DeliveryStreak instead of the
-- old per-spawn SuccessRate folder (AUDIT M21). The modifier multiplier
-- (Cities.CombinedMultiplier - the old citymodifier + 1) is applied on top,
-- same as the old missionsuccess's `amount * mods`.
function MissionService.ComputePay(rankIndex: number, population: number, streak: number, modifiers: { ModifierRoll }): number
	local weaklingBonus = 10 / rankIndex
	local base = math.floor(1 + weaklingBonus + population * 1.25 + streak * 1.25)
	return math.floor(base * Cities.CombinedMultiplier(modifiers))
end

-- Pure: a run "settles" (pays out, fails or is intercepted) exactly once -
-- whichever of the arrival check, the TimeCrunch timeout or a StatusService
-- Knocked notification gets there first wins; every other caller sees
-- `settled` already true and does nothing (AUDIT H8 - "the reward is paid
-- exactly once per run").
export type SettleState = { settled: boolean }
function MissionService.TrySettle(state: SettleState): boolean
	if state.settled then
		return false
	end
	state.settled = true
	return true
end

-- Pure: a completed delivery - the real streak (AUDIT M21) and per-city
-- route history (AUDIT M12) the modifier roll above reads back.
function MissionService.ApplySuccess(data: Data, destinationKey: string)
	data.Progress.DeliveryStreak += 1
	data.Progress.Routes[destinationKey] = (data.Progress.Routes[destinationKey] or 0) + 1
end

-- Pure: any failed/intercepted run breaks the streak. Route history is only
-- ever earned on a real delivery (ApplySuccess), never touched here.
function MissionService.ApplyFailure(data: Data)
	data.Progress.DeliveryStreak = 0
end

-- Pure: the interceptor's own save gets the reward as a Bounty number
-- (Bryan, 2026-09-29: "no board yet" - this is only the running total a
-- later bounty-board milestone will read). Never touches the courier's
-- save - AUDIT H8's "two accounts can farm this back and forth" fix is
-- that the courier's OWN copper is never reduced at all; they just never
-- get their own reward.
function MissionService.ApplyInterception(attackerData: Data, reward: number)
	attackerData.Bounty += reward
end

-- ==================== runtime types ====================

type BoardDestination = {
	key: string,
	modifiers: { ModifierRoll },
	pay: number,
}

type Board = {
	city: string,
	part: BasePart,
	destinations: { [string]: BoardDestination },
}

type RunPhase = "ToDestination" | "Returning"

type Run = {
	player: Player,
	character: Model,
	destination: string,
	destinationPosition: Vector3,
	originPosition: Vector3,
	modifiers: { ModifierRoll },
	pay: number,
	phase: RunPhase,
	returnPosition: Vector3?,
	hasCourierLoop: boolean,
	heavyCargo: boolean,
	fragile: boolean,
	timerEndsAt: number?, -- Workspace:GetServerTimeNow(), also the wire value
	pack: Instance?,
	settled: boolean,
	beaconOn: boolean,
	beaconNextAt: number,
	beaconOffAt: number?,
}

-- ==================== state ====================
-- Keyed by Player/Model, never by name - same reasoning every other service
-- in this codebase uses (StatusService, MovementService, ...).

local boards: { [Player]: Board } = {}
local runs: { [Player]: Run } = {}
local runByCharacter: { [Model]: Run } = {}
local missionLogEnabled = false

local function rollDie(max: number): number
	return math.random(1, max)
end

local function vecToTable(v: Vector3): { x: number, y: number, z: number }
	return { x = v.X, y = v.Y, z = v.Z }
end

local function hasModifier(modifiers: { ModifierRoll }, name: string): boolean
	for _, mod in modifiers do
		if mod.name == name then
			return true
		end
	end
	return false
end

local function getDeliveryPart(cityKey: string): BasePart?
	local map = Workspace:FindFirstChild("MAP")
	if map == nil then
		return nil
	end
	local missionFolder = map:FindFirstChild("MISSION")
	if missionFolder == nil then
		return nil
	end
	local part = missionFolder:FindFirstChild(Cities.DeliveryPartName(cityKey))
	if part == nil or not part:IsA("BasePart") then
		return nil
	end
	return part
end

-- ==================== attributes ====================

local function initAttributes(player: Player)
	player:SetAttribute("OnMission", false)
	player:SetAttribute("MissionDestination", "")
end

local function refreshAttributes(player: Player, data: Data)
	player:SetAttribute("MissionStreak", data.Progress.DeliveryStreak)
	player:SetAttribute("Bounty", data.Bounty)
end

-- ==================== board ====================

local function closeBoard(player: Player)
	if boards[player] == nil then
		return
	end
	boards[player] = nil
	Remotes.Server.Fire("MissionBoard", player, nil)
end

local function sendBoard(player: Player, board: Board)
	local destinationsPayload = {}
	for _, destKey in Cities.Routes[board.city] do
		local dest = board.destinations[destKey]
		if dest then
			local city = Cities.ByKey[destKey]
			table.insert(destinationsPayload, {
				key = destKey,
				name = if city then city.name else destKey,
				color = if city then city.color else { r = 1, g = 1, b = 1 },
				lore = if city then city.lore else "",
				image = if city then city.image else "",
				pay = dest.pay,
				modifiers = dest.modifiers,
			})
		end
	end
	Remotes.Server.Fire("MissionBoard", player, { city = board.city, destinations = destinationsPayload })
end

-- Builds a fresh board (rolls every destination's modifiers/pay right now -
-- AUDIT L14: the preview includes modifiers, not just the base reward) and
-- sends it. Shared by the real MissionOpenBoard handler and the dev
-- `.mission start` shortcut.
local function buildBoard(player: Player, data: Data, cityKey: string, part: BasePart): Board?
	local route = Cities.Routes[cityKey]
	if route == nil then
		return nil
	end

	local rankIndex = select(1, RankService.GetRank(player))
	local population = #Players:GetPlayers()
	local streak = data.Progress.DeliveryStreak

	local destinations: { [string]: BoardDestination } = {}
	for _, destKey in route do
		local factors = MissionService.FactorsFor(data, destKey)
		local modifiers = Cities.RollModifiers(factors, rollDie)
		local pay = MissionService.ComputePay(rankIndex, population, streak, modifiers)
		destinations[destKey] = { key = destKey, modifiers = modifiers, pay = pay }
	end

	return { city = cityKey, part = part, destinations = destinations }
end

-- ==================== package model ====================
-- Ported from the old MissionHandler:412-428 (the old `packagetypes`
-- table). ReplicatedFirst.Objects isn't synced by Rojo (Studio-only art,
-- same as RF.VFX/RF.SFX) - missing gracefully degrades to no visible
-- package instead of erroring, same defensive pattern CharacterService uses
-- for RF.Assets/RF.VFX/RF.SFX lookups.

local PACKAGE_TEMPLATE_NAMES = { "Package1", "Package2" }

local function attachPackage(character: Model): Instance?
	local objects = ReplicatedFirst:FindFirstChild("Objects")
	if objects == nil then
		log:Warn("ReplicatedFirst.Objects is missing - starting a delivery with no visible package")
		return nil
	end
	local torso = character:FindFirstChild("Torso")
	if torso == nil or not torso:IsA("BasePart") then
		return nil
	end

	local templateName = PACKAGE_TEMPLATE_NAMES[math.random(1, #PACKAGE_TEMPLATE_NAMES)]
	local template = objects:FindFirstChild(templateName)
	if template == nil or not template:IsA("Model") then
		log:Warn(string.format("ReplicatedFirst.Objects.%s is missing or not a Model", templateName))
		return nil
	end

	local pack = (template:Clone() :: Model)
	pack.Name = "Pack"
	local primary = pack.PrimaryPart
	if primary == nil then
		pack:Destroy()
		return nil
	end
	primary.CFrame = torso.CFrame

	local main = pack:FindFirstChild("Main")
	if main and main:IsA("BasePart") then
		if pack:FindFirstChild("Pack1") then
			main.CFrame = torso.CFrame:ToWorldSpace(CFrame.new(0, 0, 0.3) * CFrame.Angles(0, math.rad(180), 0))
		elseif pack:FindFirstChild("Pack2") then
			main.CFrame = torso.CFrame:ToWorldSpace(CFrame.new(0, 0, 1.25) * CFrame.Angles(math.rad(270), math.rad(90), math.rad(90)))
		end
	end

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = primary
	weld.Part1 = torso
	weld.Parent = pack

	pack.Parent = character
	return pack
end

-- ==================== run lifecycle ====================

local function sendUpdate(player: Player, run: Run, state: string)
	local payload: { [string]: any } = {
		state = state,
		destination = run.destination,
		destinationPosition = vecToTable(run.destinationPosition),
		modifiers = run.modifiers,
		pay = run.pay,
	}
	if run.returnPosition then
		payload.returnPosition = vecToTable(run.returnPosition :: Vector3)
	end
	if run.timerEndsAt then
		payload.timerEnds = run.timerEndsAt
	end
	Remotes.Server.Fire("MissionUpdate", player, payload)
end

local function startRun(
	player: Player,
	character: Model,
	originPosition: Vector3,
	destinationKey: string,
	destinationPosition: Vector3,
	modifiers: { ModifierRoll },
	pay: number
)
	local now = Workspace:GetServerTimeNow()
	local hasTimeCrunch = hasModifier(modifiers, "TimeCrunch")

	local run: Run = {
		player = player,
		character = character,
		destination = destinationKey,
		destinationPosition = destinationPosition,
		originPosition = originPosition,
		modifiers = modifiers,
		pay = pay,
		phase = "ToDestination",
		returnPosition = nil,
		hasCourierLoop = hasModifier(modifiers, "CourierLoop"),
		heavyCargo = hasModifier(modifiers, "HeavyCargo"),
		fragile = hasModifier(modifiers, "FragilePackage"),
		timerEndsAt = if hasTimeCrunch then now + Config.Missions.TimeCrunchSeconds else nil,
		pack = attachPackage(character),
		settled = false,
		beaconOn = false,
		beaconNextAt = now + Config.Missions.Beacon.everySeconds,
		beaconOffAt = nil,
	}

	if run.heavyCargo then
		MovementService.SetModifier(character, "HeavyCargo", Config.Missions.HeavyCargoSpeedMult)
	end

	runs[player] = run
	runByCharacter[character] = run

	player:SetAttribute("OnMission", true)
	player:SetAttribute("MissionDestination", destinationKey)

	sendUpdate(player, run, "Started")
end

local function cleanupRun(player: Player, run: Run)
	if run.pack then
		run.pack:Destroy()
	end
	-- Cleared on ANY end (AUDIT M13: the old heavy-cargo slow only cleared
	-- on success and stuck around after an interception until respawn).
	if run.heavyCargo then
		MovementService.ClearModifier(run.character, "HeavyCargo")
	end
	pcall(function()
		run.character:SetAttribute("CourierBeacon", false)
	end)

	player:SetAttribute("OnMission", false)
	player:SetAttribute("MissionDestination", "")

	runs[player] = nil
	if runByCharacter[run.character] == run then
		runByCharacter[run.character] = nil
	end
end

local function finishRun(player: Player, run: Run)
	if not MissionService.TrySettle(run) then
		return
	end

	EconomyService.GiveCopperValue(player, run.pay, string.format("Delivery: %s", run.destination))
	RankService.AddMagoi(player, Config.Missions.MagoiPerDelivery, "Delivery")
	RankService.AddDeed(player, "Gold", 1)

	local data = DataService.Get(player)
	if data then
		MissionService.ApplySuccess(data, run.destination)
		refreshAttributes(player, data)
	end

	sendUpdate(player, run, "Finished")
	cleanupRun(player, run)

	if missionLogEnabled then
		log:Info(string.format("%s delivered to %s for %d Copper", player.Name, run.destination, run.pay))
	end
end

local function failRun(player: Player, run: Run, reason: string)
	if not MissionService.TrySettle(run) then
		return
	end

	local data = DataService.Get(player)
	if data then
		MissionService.ApplyFailure(data)
		refreshAttributes(player, data)
	end

	sendUpdate(player, run, "Failed")
	cleanupRun(player, run)

	if missionLogEnabled then
		log:Info(string.format("%s's delivery to %s failed (%s)", player.Name, run.destination, reason))
	end
end

-- AUDIT H8: the attacker is paid the run's full reward INSTANTLY, exactly
-- once (TrySettle), and the courier's own wallet is never touched at all
-- (nothing to farm back and forth - see ApplyInterception's own comment).
local function interceptRun(courier: Player, run: Run, attacker: Player)
	if not MissionService.TrySettle(run) then
		return
	end

	EconomyService.GiveCopperValue(attacker, run.pay, string.format("Delivery interception: %s", run.destination))
	RankService.AddDeed(attacker, "Black", 1)

	local attackerData = DataService.Get(attacker)
	if attackerData then
		MissionService.ApplyInterception(attackerData, run.pay)
		refreshAttributes(attacker, attackerData)
	end

	local courierData = DataService.Get(courier)
	if courierData then
		MissionService.ApplyFailure(courierData)
		refreshAttributes(courier, courierData)
	end

	sendUpdate(courier, run, "Intercepted")
	cleanupRun(courier, run)

	log:Info(string.format("%s intercepted %s's delivery to %s for %d Copper", attacker.Name, courier.Name, run.destination, run.pay))
end

-- ==================== remotes ====================

local function onOpenBoard(player: Player, cityKey: string)
	if runs[player] then
		return
	end
	local character = player.Character
	if character == nil then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return
	end
	local part = getDeliveryPart(cityKey)
	if part == nil then
		return
	end
	if ((root :: BasePart).Position - part.Position).Magnitude > Config.Missions.OpenStuds then
		return
	end

	local data = DataService.Get(player)
	if data == nil then
		return
	end

	local board = buildBoard(player, data, cityKey, part)
	if board == nil then
		return
	end

	boards[player] = board
	sendBoard(player, board)

	if missionLogEnabled then
		log:Info(string.format("%s opened the %s delivery board", player.Name, cityKey))
	end
end

local function onMissionStart(player: Player, destinationKey: string)
	local board = boards[player]
	if board == nil or runs[player] ~= nil then
		return
	end
	local dest = board.destinations[destinationKey]
	-- H7: rejected unless it's on THIS board's own route - the remote's own
	-- Validate.string(oneOf = Cities.Keys) already stops a nonsense string,
	-- this is the real "is it actually reachable from here" check.
	if dest == nil or not MissionService.IsOnRoute(board.city, destinationKey) then
		log:Warn(string.format("%s tried to start a delivery to %s, not on the %s board", player.Name, destinationKey, board.city))
		return
	end

	local character = player.Character
	if character == nil then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return
	end

	local destPart = getDeliveryPart(destinationKey)
	if destPart == nil then
		return
	end

	local originPosition = board.part.Position
	closeBoard(player)
	startRun(player, character, originPosition, destinationKey, destPart.Position, dest.modifiers, dest.pay)

	if missionLogEnabled then
		log:Info(string.format("%s started a delivery from %s to %s (%d Copper)", player.Name, board.city, destinationKey, dest.pay))
	end
end

local function onMissionExit(player: Player)
	local run = runs[player]
	if run then
		failRun(player, run, "left")
	end
	closeBoard(player)
end

-- ==================== interception / fragile package ====================

local function onStatusChanged(character: Model, status: string, active: boolean)
	if not active then
		return
	end
	local run = runByCharacter[character]
	if run == nil then
		return
	end

	if status == "Hit" then
		if run.fragile then
			failRun(run.player, run, "fragile")
		end
	elseif status == "Knocked" then
		local info = StatusService.Get(character, "Knocked")
		local by = if info and type(info.data) == "table" then (info.data :: any).by else nil
		local attacker = if type(by) == "string" then Players:FindFirstChild(by) else nil
		if attacker and attacker:IsA("Player") and (attacker :: Player) ~= run.player then
			interceptRun(run.player, run, attacker :: Player)
		else
			failRun(run.player, run, "knocked")
		end
	end
end

-- ==================== shared loop (AUDIT H9: no per-frame/per-board loops) ====================

local function tick()
	local now = Workspace:GetServerTimeNow()

	for player, board in boards do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root == nil or not (root :: Instance):IsA("BasePart") then
			closeBoard(player)
			continue
		end
		if ((root :: BasePart).Position - board.part.Position).Magnitude > Config.Missions.BoardCloseStuds then
			closeBoard(player)
		end
	end

	for player, run in runs do
		local character = player.Character
		if character == nil or character ~= run.character or character.Parent == nil then
			-- CharacterRemoving already fails the run in the normal case;
			-- this is a defensive catch for an ordering edge case, never a
			-- silent leak (AUDIT H9's "everything cleaned on leave/respawn").
			failRun(player, run, "respawn")
			continue
		end

		if run.timerEndsAt and now >= run.timerEndsAt then
			failRun(player, run, "timer")
			continue
		end

		if run.beaconOn then
			if run.beaconOffAt and now >= run.beaconOffAt then
				run.beaconOn = false
				run.beaconOffAt = nil
				character:SetAttribute("CourierBeacon", false)
				run.beaconNextAt = now + Config.Missions.Beacon.everySeconds
			end
		elseif now >= run.beaconNextAt then
			run.beaconOn = true
			run.beaconOffAt = now + Config.Missions.Beacon.forSeconds
			character:SetAttribute("CourierBeacon", true)
		end

		local root = character:FindFirstChild("HumanoidRootPart")
		if root == nil or not root:IsA("BasePart") then
			continue
		end

		local targetPosition = if run.phase == "ToDestination" then run.destinationPosition else run.originPosition
		if ((root :: BasePart).Position - targetPosition).Magnitude <= Config.Missions.ArriveStuds then
			if run.phase == "ToDestination" and run.hasCourierLoop then
				-- "Cleared" (not "Finished" - the run isn't over, and not
				-- another "Started" - the contract's 5 states don't have a
				-- "leg 2" one): CourierLoop's first leg is done, now loop
				-- back with returnPosition set. A judgment call on an
				-- otherwise-unused state name; documented for M5C-02.
				run.phase = "Returning"
				run.returnPosition = run.originPosition
				sendUpdate(player, run, "Cleared")
			else
				finishRun(player, run)
			end
		end
	end
end

-- ==================== leave / respawn cleanup ====================

local function onCharacterRemoving(player: Player)
	local run = runs[player]
	if run then
		failRun(player, run, "respawn")
	end
	closeBoard(player)
end

-- ==================== dev commands ====================

local function resolveCityArg(text: string?): string?
	if text == nil then
		return nil
	end
	local lower = text:lower()
	for _, key in Cities.Keys do
		if key:lower() == lower then
			return key
		end
	end
	return nil
end

local function modNames(modifiers: { ModifierRoll }): string
	if #modifiers == 0 then
		return "none"
	end
	local names: { string } = {}
	for _, mod in modifiers do
		table.insert(names, mod.name)
	end
	return table.concat(names, ", ")
end

local function missionStartDevCommand(caller: Player, args: { string }): string
	local cityKey = resolveCityArg(args[1])
	if cityKey == nil then
		return "usage: .mission start <city> [player]"
	end
	local target, err = DevService.ResolvePlayer(caller, args[2])
	if target == nil then
		return err or "player not found"
	end
	if runs[target] then
		return string.format("%s is already on a delivery", target.Name)
	end
	local character = target.Character
	if character == nil then
		return string.format("%s has no character", target.Name)
	end
	local data = DataService.Get(target)
	if data == nil then
		return string.format("%s has no save loaded", target.Name)
	end
	local destPart = getDeliveryPart(cityKey)
	if destPart == nil then
		return string.format("Workspace.MAP.MISSION.%s is missing", Cities.DeliveryPartName(cityKey))
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	local originPosition = if root and root:IsA("BasePart") then (root :: BasePart).Position else destPart.Position

	local rankIndex = select(1, RankService.GetRank(target))
	local population = #Players:GetPlayers()
	local factors = MissionService.FactorsFor(data, cityKey)
	local modifiers = Cities.RollModifiers(factors, rollDie)
	local pay = MissionService.ComputePay(rankIndex, population, data.Progress.DeliveryStreak, modifiers)

	closeBoard(target)
	startRun(target, character, originPosition, cityKey, destPart.Position, modifiers, pay)

	return string.format("%s's delivery to %s started: %d Copper, modifiers: %s", target.Name, cityKey, pay, modNames(modifiers))
end

local function missionFinishDevCommand(caller: Player, args: { string }): string
	local target, err = DevService.ResolvePlayer(caller, args[1])
	if target == nil then
		return err or "player not found"
	end
	local run = runs[target]
	if run == nil then
		return string.format("%s has no active delivery", target.Name)
	end
	finishRun(target, run)
	return string.format("%s's delivery force-finished", target.Name)
end

local function missionFailDevCommand(caller: Player, args: { string }): string
	local target, err = DevService.ResolvePlayer(caller, args[1])
	if target == nil then
		return err or "player not found"
	end
	local run = runs[target]
	if run == nil then
		return string.format("%s has no active delivery", target.Name)
	end
	failRun(target, run, "dev")
	return string.format("%s's delivery force-failed", target.Name)
end

local function missionStreakDevCommand(caller: Player, args: { string }): string
	local n = tonumber(args[1])
	if n == nil then
		return "usage: .mission streak <n> [player]"
	end
	local target, err = DevService.ResolvePlayer(caller, args[2])
	if target == nil then
		return err or "player not found"
	end
	local data = DataService.Get(target)
	if data == nil then
		return string.format("%s has no save loaded", target.Name)
	end
	data.Progress.DeliveryStreak = math.max(0, math.floor(n))
	refreshAttributes(target, data)
	return string.format("%s's delivery streak set to %d", target.Name, data.Progress.DeliveryStreak)
end

local function missionLogDevCommand(_caller: Player, args: { string }): string
	local mode = args[1] and args[1]:lower()
	if mode ~= "on" and mode ~= "off" then
		return "usage: .mission log on|off"
	end
	missionLogEnabled = mode == "on"
	return string.format("mission logging %s", mode)
end

-- Dispatches ".mission <sub> ..." to the right handler above - one dev
-- command, several sub-commands, same idiom as ".shop"/".npc"/".dummy".
local function missionCommand(caller: Player, args: { string }): string
	local sub = args[1] and args[1]:lower()
	local rest = table.clone(args)
	if #rest > 0 then
		table.remove(rest, 1)
	end

	if sub == "start" then
		return missionStartDevCommand(caller, rest)
	elseif sub == "finish" then
		return missionFinishDevCommand(caller, rest)
	elseif sub == "fail" then
		return missionFailDevCommand(caller, rest)
	elseif sub == "streak" then
		return missionStreakDevCommand(caller, rest)
	elseif sub == "log" then
		return missionLogDevCommand(caller, rest)
	end
	return "usage: .mission start <city> [player] | finish [player] | fail [player] | streak <n> [player] | log on|off"
end

local function registerDevCommands()
	DevService.Register(
		"mission",
		"start <city> [player] | finish [player] | fail [player] | streak <n> [player] | log on|off - delivery missions",
		missionCommand
	)
end

-- ==================== service ====================

function MissionService:Init()
	registerDevCommands()
end

function MissionService:Start()
	Remotes.Server.On("MissionOpenBoard", onOpenBoard)
	Remotes.Server.On("MissionStart", onMissionStart)
	Remotes.Server.On("MissionExit", onMissionExit)

	StatusService.Changed:Connect(onStatusChanged)

	local function hookPlayer(player: Player)
		player.CharacterRemoving:Connect(function()
			onCharacterRemoving(player)
		end)
	end
	Players.PlayerAdded:Connect(hookPlayer)
	for _, player in Players:GetPlayers() do
		hookPlayer(player)
	end

	-- A safety-net local cleanup only - CharacterRemoving (above) already
	-- ran the real failRun (data mutation, EconomyService/RankService) while
	-- the character still existed; this just drops any local state that
	-- somehow survived it (e.g. a board with no character at all).
	Players.PlayerRemoving:Connect(function(player: Player)
		boards[player] = nil
		local run = runs[player]
		if run then
			runs[player] = nil
			if runByCharacter[run.character] == run then
				runByCharacter[run.character] = nil
			end
		end
	end)

	local function loadAttributes(player: Player)
		local data = DataService.Get(player)
		if data then
			initAttributes(player)
			refreshAttributes(player, data)
		end
	end
	DataService.Loaded:Connect(loadAttributes)
	for _, player in Players:GetPlayers() do
		if DataService.IsLoaded(player) then
			loadAttributes(player)
		end
	end

	task.spawn(function()
		while true do
			task.wait(Config.Missions.Tick)
			tick()
		end
	end)
end

return MissionService
