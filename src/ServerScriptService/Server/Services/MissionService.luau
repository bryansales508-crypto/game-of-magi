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
-- REVIEW-M5C-01 fix round (CHANGES NEEDED): H1 (modifier displayName, see
-- Shared/Data/Cities.luau), H2 (the CourierLoop return leg sends "Started",
-- not "Cleared"), M1 (the shared tick is pcall-wrapped), M2 (interception
-- needs distance/time into the run - Bryan's call, Config.Missions.
-- InterceptMin*), M3 (board rolls are cached per player per destination
-- until a run to it starts), M5 (FragilePackage/VIP react to CombatService.
-- HitLanded - ANY landed hit, not just the Heavy-only `Hit` status), M6
-- (the package's FragilePackage/HighlyValuable looks restored), L1 (leaving
-- fails the run before local state is dropped), L2 (Mission attributes
-- refresh after a new life), L3 (the interceptor is resolved by UserId, not
-- name - see CombatService's byUserId).
--
-- Bryan's own follow-up refinement (after the fix round): failing a
-- modifier (TimeCrunch's timer, a FragilePackage/VIP hit, Clear the Route
-- with no knockout) never ends the run any more - it just drops that
-- modifier's own share of the payout and tells the client which pop-out to
-- grey (`MissionUpdate` state "ModifierFailed", `{key}`). Only leaving,
-- dying, respawning, an interception, or `.mission fail` end a run early.
-- HighlyValuable also keeps `CourierBeacon` on for the WHOLE run now,
-- instead of pulsing on the shared 30s/3s cycle everyone else uses.
--
-- Ported from (now removed) SSS/MISC/MissionHandler/init.server.luau,
-- RS/Modules/MissionDeliniation.luau and RS/Modules/RewardHandler.luau; see
-- docs/SYSTEMS.md section 7 and docs/reference/m5c-studio-dump.md.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local TweenService = game:GetService("TweenService")

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
local CombatService = require(script.Parent.CombatService)
local DevService = require(script.Parent.DevService)

local log = Log.new("MissionService")

type Data = SaveSchema.Data
type ModifierRoll = Cities.ModifierRoll
type RunPhase = "ToDestination" | "Returning"

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

-- Pure: the pre-multiplier base amount (rank/population/streak only - no
-- modifiers). Cached once per board roll (M3) and combined with whichever
-- modifiers are still intact at settlement (CurrentPay below) to get the
-- actual payout - kept separate so a modifier failing DURING the run only
-- ever lowers the final number, never recomputes rank/population/streak
-- from a different moment. `rankIndex` replaces the old race-branched
-- "level" (Ranks.rankFor never returns less than 1, so 10/rankIndex can't
-- divide by zero - AUDIT L15); `streak` is the real, saved DeliveryStreak,
-- not the old per-spawn SuccessRate folder (AUDIT M21).
function MissionService.BaseAmount(rankIndex: number, population: number, streak: number): number
	return math.floor(1 + 10 / rankIndex + population * 1.25 + streak * 1.25)
end

-- Pure: the old RewardHandler.rewardcaculation × citymodifier formula,
-- given a fixed set of modifiers - used for the board's PREVIEW pay (every
-- rolled modifier assumed intact, the best case) and by the self-test.
-- CurrentPay below is the live equivalent once some may have failed.
-- Cities.CombinedMultiplier is additive (REVIEW-M5C-01B F2, confirmed with
-- Bryan), not a product of the modifiers' own multipliers.
function MissionService.ComputePay(rankIndex: number, population: number, streak: number, modifiers: { ModifierRoll }): number
	return math.floor(MissionService.BaseAmount(rankIndex, population, streak) * Cities.CombinedMultiplier(modifiers))
end

-- Pure (Bryan's refinement): the ACTUAL payout at settlement - `baseAmount`
-- combined only with whichever rolled modifiers are still intact (not
-- listed in `failedKeys`). A modifier failing during the run (TimeCrunch's
-- timer, a landed hit against FragilePackage/VIP, Clear the Route with no
-- knockout) never ends the run any more - it just drops out of this sum.
function MissionService.CurrentPay(baseAmount: number, modifiers: { ModifierRoll }, failedKeys: { [string]: boolean }): number
	local intact: { ModifierRoll } = {}
	for _, mod in modifiers do
		if not failedKeys[mod.key] then
			table.insert(intact, mod)
		end
	end
	return math.floor(baseAmount * Cities.CombinedMultiplier(intact))
end

-- Pure (REVIEW-M5C-01B F4, Bryan's call): what an INTERCEPTOR is actually
-- paid - `failedKeysBeforeHit` is `failedKeys` as they stood BEFORE the
-- very hit that knocked the courier out (see onHitLanded's own snapshot),
-- so the same landed hit that ends the run never also costs the
-- interceptor whatever it just failed for the courier (a VIP courier's 2x
-- or Fragile's 1.3x otherwise always vanished into the killing blow
-- itself). Clear the Route's bonus is force-excluded outright, always -
-- the interceptor didn't clear anything (if anything, they're the threat
-- it was about), whether or not the courier happened to earn it against
-- someone else earlier in the run.
function MissionService.InterceptPay(baseAmount: number, modifiers: { ModifierRoll }, failedKeysBeforeHit: { [string]: boolean }): number
	local excluding: { [string]: boolean } = table.clone(failedKeysBeforeHit)
	excluding["CleartheRoute"] = true
	return MissionService.CurrentPay(baseAmount, modifiers, excluding)
end

-- Pure (the intercepted mark, Bryan): every interception adds one stack to
-- the COURIER (Progress.Intercepted) - this is the multiplier that stack
-- count earns them, halved per stack with a 10% floor so it never hits
-- zero. Applies to that player's own board offers, their own reduced
-- payout if they still complete a marked delivery, and an interceptor's
-- own payout while the victim is marked (see ApplyOfferMultiplier/
-- interceptRun) - `stacks == 0` is exactly 1 (no reduction at all).
function MissionService.OfferMultiplier(stacks: number): number
	return math.max(Config.Missions.InterceptedFloor, Config.Missions.InterceptedDecay ^ stacks)
end

-- Pure: applies an already-computed OfferMultiplier to an already-computed
-- pay number - kept as its own tiny step (rather than folded into
-- ComputePay/CurrentPay/InterceptPay) so none of those - or their existing
-- self-tests - need to know the intercepted mark exists at all; a run's own
-- `offerMultiplier` is fixed once at roll time (same reasoning as
-- `baseAmount`), same as everything else this stacks with.
function MissionService.ApplyOfferMultiplier(pay: number, offerMultiplier: number): number
	return math.floor(pay * offerMultiplier)
end

-- Pure (REVIEW-M5C-01C H1): the board-preview pay for a cached
-- `BoardDestination`, applying `offerMultiplier` FRESH every call rather
-- than one baked in at roll time - `baseAmount`/`modifiers` are genuinely
-- fixed the moment a destination is rolled (M3), but the intercepted mark
-- can change while that same cache entry is still sitting in `boardRolls`
-- (a DIFFERENT destination's run gets intercepted, a clearing delivery,
-- `.mission mark`), so this is the one place that reads it. No modifier is
-- ever pre-failed for a preview (empty failedKeys - the best case, same as
-- ComputePay).
function MissionService.PreviewPay(baseAmount: number, modifiers: { ModifierRoll }, offerMultiplier: number): number
	return MissionService.ApplyOfferMultiplier(MissionService.CurrentPay(baseAmount, modifiers, {}), offerMultiplier)
end

-- Pure: the courier's OWN mark advances by one on every interception -
-- never cleared by a failure, only by ClearIntercepted below (a completed
-- delivery).
function MissionService.MarkIntercepted(data: Data)
	data.Progress.Intercepted += 1
end

-- Pure: one completed delivery washes the mark away entirely - AFTER that
-- delivery itself is paid at whatever the reduced rate was at the time it
-- was rolled (finishRun's own ordering, not this function's).
function MissionService.ClearIntercepted(data: Data)
	data.Progress.Intercepted = 0
end

-- Pure (Bryan): an interceptor earns a Black Rukh only if the victim
-- WASN'T already marked before this interception - `offerMultiplierAtStart`
-- is a run's own `offerMultiplier` (fixed at roll/start time, i.e. before
-- this interception's own mark), which is exactly 1 only when stacks was 0
-- at that point.
function MissionService.InterceptorEarnsBlackRukh(offerMultiplierAtStart: number): boolean
	return offerMultiplierAtStart >= 1
end

-- Pure (Bryan's post-review refinement): marks one modifier failed in
-- `failedKeys`, idempotently - returns true only the first time (so a
-- caller fires the ModifierFailed update/log exactly once per modifier per
-- run, even if the same trigger fires repeatedly, e.g. several landed hits
-- against FragilePackage).
function MissionService.MarkFailed(failedKeys: { [string]: boolean }, key: string): boolean
	if failedKeys[key] then
		return false
	end
	failedKeys[key] = true
	return true
end

-- Pure (REVIEW-M5C-01B F3): the failed-keys SET as an array, for the wire.
-- Every MissionUpdate carries this so the client can re-grey already-failed
-- pop-outs on ANY rebuild - most importantly the CourierLoop return leg's
-- own "Started" (which tears down and rebuilds every pop-out from
-- `modifiers` alone otherwise, un-greying a TimeCrunch/Fragile/VIP that
-- already failed on the first leg) - without ever re-firing the one-shot
-- `"ModifierFailed"` update for a key that's already been sent.
function MissionService.FailedKeysList(failedKeys: { [string]: boolean }): { string }
	local list: { string } = {}
	for key in failedKeys do
		table.insert(list, key)
	end
	return list
end

-- Pure (H2): decides the phase transition on arrival. `"Returning"` with a
-- `"Started"` update means loop back (CourierLoop) - REVIEW-M5C-01 H2: the
-- client only re-arms its tracker on `"Started"` with `returnPosition` set;
-- it tears the WHOLE run down on any other state, including the old
-- `"Cleared"` this used to send. `nil` means the run is actually done
-- (finishRun decides Finished vs. whatever else).
function MissionService.OnArrival(phase: RunPhase, hasCourierLoop: boolean): (RunPhase?, string?)
	if phase == "ToDestination" and hasCourierLoop then
		return "Returning", "Started"
	end
	return nil, nil
end

-- Pure (M2, lead decision, Bryan may change it): an interception only pays
-- if the courier is genuinely out on the route - AUDIT H8's remaining gap
-- was two accounts farming the reward by knocking a courier out right next
-- to the board they just opened, with no travel at all.
function MissionService.CanIntercept(distanceFromOrigin: number, elapsedSeconds: number): boolean
	return distanceFromOrigin >= Config.Missions.InterceptMinStuds or elapsedSeconds >= Config.Missions.InterceptMinSeconds
end

-- Pure (M3): the board-roll cache's own get-or-roll logic - extracted so
-- "reopening the board doesn't re-roll" is testable with a fake cache and
-- no Player/DataService/remote involved. `roll` only runs on a cache miss;
-- a hit returns the exact same table every time (the old MissionHandler's
-- `CityMods`, ported: once rolled, a destination's modifiers/pay don't
-- change until a run to it actually starts and clears the entry).
function MissionService.GetOrRoll<T>(cache: { [string]: T }, key: string, roll: () -> T): T
	local cached = cache[key]
	if cached ~= nil then
		return cached
	end
	local entry = roll()
	cache[key] = entry
	return entry
end

-- Pure: a run "settles" (pays out, fails or is intercepted) exactly once -
-- whichever of the arrival check or a disqualifying event gets there first
-- wins; every other caller sees `settled` already true and does nothing
-- (AUDIT H8 - "the reward is paid exactly once per run"). Unrelated to
-- MarkFailed above: a failed MODIFIER never settles the run by itself.
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

-- REVIEW-M5C-01C H1: deliberately carries NO offerMultiplier/pay of its
-- own - `rank`/`population`/`streak` (baked into `baseAmount`) and the
-- modifier roll are genuinely fixed the moment a destination is rolled
-- (M3's whole point), but the intercepted mark is NOT: it can change while
-- this exact cache entry is still sitting in `boardRolls` (an interception
-- on a DIFFERENT destination's run, a clearing delivery, `.mission mark`),
-- so baking a multiplier in here would go stale exactly like it just did.
-- PreviewPay (below) applies the CURRENT multiplier fresh every time this
-- is read, so the cache can never disagree with `Progress.Intercepted`.
type BoardDestination = {
	key: string,
	modifiers: { ModifierRoll },
	baseAmount: number,
}

type Board = {
	city: string,
	part: BasePart,
	destinations: { [string]: BoardDestination },
}

type ValuablePulsePhase = "FadeIn" | "Hold" | "FadeOut" | "Off"

type Run = {
	player: Player,
	character: Model,
	destination: string,
	destinationPosition: Vector3,
	originPosition: Vector3,
	modifiers: { ModifierRoll }, -- the full rolled set, immutable through the run
	baseAmount: number,
	offerMultiplier: number, -- the intercepted mark, fixed at roll time (>= 1 means the courier wasn't marked at start - no Black Rukh withheld from an interceptor)
	phase: RunPhase,
	returnPosition: Vector3?,
	hasCourierLoop: boolean,
	heavyCargo: boolean,
	hasFragilePackage: boolean,
	hasVip: boolean,
	hasClearTheRoute: boolean,
	hasHighlyValuable: boolean,
	clearedRoute: boolean, -- M4: earned a knockout during the run
	failedKeys: { [string]: boolean }, -- Bryan's refinement: dropped from the payout, run continues
	-- F4: a snapshot of failedKeys taken right before the courier's own
	-- Fragile/VIP react to a landed hit (onHitLanded) - nil until the first
	-- hit lands. interceptRun uses this (falling back to failedKeys itself
	-- if a knockout never went through a real landed hit, e.g. a dev
	-- `.knock`) so the SAME hit that ends the run in an interception never
	-- also costs the interceptor whatever it just failed.
	preHitFailedKeys: { [string]: boolean }?,
	timerEndsAt: number?, -- Workspace:GetServerTimeNow(), also the wire value
	startedAt: number, -- for M2's elapsed-seconds gate
	pack: Instance?,
	valuableHighlight: Highlight?,
	valuablePhase: ValuablePulsePhase?,
	valuablePhaseEndsAt: number?,
	settled: boolean,
	beaconOn: boolean,
	beaconPermanent: boolean, -- HighlyValuable: CourierBeacon stays true for the whole run
	beaconNextAt: number,
	beaconOffAt: number?,
}

-- ==================== state ====================
-- Keyed by Player/Model, never by name - same reasoning every other service
-- in this codebase uses (StatusService, MovementService, ...).

local boards: { [Player]: Board } = {}
-- M3: cached per player per destination key, surviving repeated
-- MissionOpenBoard calls (the old CityMods) - cleared only when a run to
-- that destination actually starts (clearCachedRoll).
local boardRolls: { [Player]: { [string]: BoardDestination } } = {}
local runs: { [Player]: Run } = {}
local runByCharacter: { [Model]: Run } = {}
local missionLogEnabled = false

local function rollDie(max: number): number
	return math.random(1, max)
end

local function vecToTable(v: Vector3): { x: number, y: number, z: number }
	return { x = v.X, y = v.Y, z = v.Z }
end

local function hasModifier(modifiers: { ModifierRoll }, key: string): boolean
	for _, mod in modifiers do
		if mod.key == key then
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

-- Pure (REVIEW-M5C-01 H1, exported and self-tested per REVIEW-M5C-01B F5):
-- every modifier sent to the client is `{ key, name, chance, text }` -
-- `key` is the internal name (what a ModifierFailed update's own `key`
-- matches), and `name` is the display name. Never the internal key under
-- `name` - the client's Time Crunch/Courier Loop special-cases and every
-- pop-out title match on it.
function MissionService.WireModifiers(modifiers: { ModifierRoll }): { any }
	local list = {}
	for _, mod in modifiers do
		table.insert(list, { key = mod.key, name = mod.displayName, chance = mod.chance, text = mod.text })
	end
	return list
end

local function sendBoard(player: Player, board: Board, data: Data)
	-- REVIEW-M5C-01C H1: computed fresh from the CURRENT save, not cached -
	-- a board destination's own `baseAmount`/`modifiers` are fixed at roll
	-- time (M3), but the intercepted mark isn't, so it's applied here every
	-- single send instead of being baked into the cache.
	local offerMultiplier = MissionService.OfferMultiplier(data.Progress.Intercepted)

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
				pay = MissionService.PreviewPay(dest.baseAmount, dest.modifiers, offerMultiplier),
				modifiers = MissionService.WireModifiers(dest.modifiers),
			})
		end
	end
	-- The intercepted mark (Bryan): a headline figure for the board itself -
	-- `intercepted` the player's CURRENT stack count, `offerMultiplier` what
	-- it's worth right now - the same multiplier every destination's `pay`
	-- above was just computed with, so the header and the offers can never
	-- disagree.
	Remotes.Server.Fire("MissionBoard", player, {
		city = board.city,
		destinations = destinationsPayload,
		intercepted = data.Progress.Intercepted,
		offerMultiplier = offerMultiplier,
	})
end

-- Rolls one destination fresh (never cached itself - GetOrRoll/
-- getOrRollDestination below own the caching).
local function rollDestination(player: Player, data: Data, destKey: string): BoardDestination
	local rankIndex = select(1, RankService.GetRank(player))
	local population = #Players:GetPlayers()
	local streak = data.Progress.DeliveryStreak
	local factors = MissionService.FactorsFor(data, destKey)
	local modifiers = Cities.RollModifiers(factors, rollDie)
	local baseAmount = MissionService.BaseAmount(rankIndex, population, streak)
	return { key = destKey, modifiers = modifiers, baseAmount = baseAmount }
end

-- M3: reuses a player's existing roll for `destKey` if one is still cached
-- (AUDIT-adjacent fix - REVIEW-M5C-01 M3: reopening the board used to
-- re-roll every time, letting a player fish for VIP/HighlyValuable).
local function getOrRollDestination(player: Player, data: Data, destKey: string): BoardDestination
	local cache = boardRolls[player]
	if cache == nil then
		cache = {}
		boardRolls[player] = cache
	end
	return MissionService.GetOrRoll(cache, destKey, function()
		return rollDestination(player, data, destKey)
	end)
end

-- The roll is "used up" the moment a run to it actually starts - the next
-- board open rolls that destination fresh again.
local function clearCachedRoll(player: Player, destKey: string)
	local cache = boardRolls[player]
	if cache then
		cache[destKey] = nil
	end
end

-- Builds a board from whatever's cached (or freshly rolled) for each
-- destination on the route (AUDIT L14: the preview pay already includes
-- modifiers). Shared by the real MissionOpenBoard handler; the dev
-- `.mission start` shortcut rolls its own one-off instead (bypasses the
-- board/cache entirely by design).
local function buildBoard(player: Player, data: Data, cityKey: string, part: BasePart): Board?
	local route = Cities.Routes[cityKey]
	if route == nil then
		return nil
	end

	local destinations: { [string]: BoardDestination } = {}
	for _, destKey in route do
		destinations[destKey] = getOrRollDestination(player, data, destKey)
	end

	return { city = cityKey, part = part, destinations = destinations }
end

-- ==================== package model & modifier looks ====================
-- Ported from the old MissionHandler:412-428 (the old `packagetypes`
-- table). ReplicatedFirst.Objects/VFX aren't synced by Rojo (Studio-only
-- art, same as RF.SFX) - missing gracefully degrades (no visible package,
-- or no FragilePackage/HighlyValuable look) instead of erroring, same
-- defensive pattern CharacterService uses for RF.Assets/RF.VFX/RF.SFX.

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

-- REVIEW-M5C-01 M6: the old FragilePackage look (MissionHandler:276-286) -
-- turns the pack to glass. Cosmetic only; never reverted even once the
-- modifier fails (a landed hit), same as the old code.
local FRAGILE_COLOR = Color3.fromRGB(168, 187, 208)

local function applyFragileLook(pack: Instance?)
	if pack == nil then
		return
	end
	if pack:FindFirstChild("Pack1") then
		for _, part in pack:GetDescendants() do
			if part:IsA("MeshPart") then
				part.Material = Enum.Material.Glass
				part.Color = FRAGILE_COLOR
			end
		end
	else
		local main = pack:FindFirstChild("Main")
		if main and main:IsA("BasePart") then
			main.Material = Enum.Material.Glass
			main.Color = FRAGILE_COLOR
		end
	end
end

-- REVIEW-M5C-01 M6: the old HighlyValuable look (MissionHandler:303-328) -
-- trueSparkle/sparkle1/sparkle2 VFX plus a gold Highlight on the pack that
-- pulses 1s in, 6s on, 1s out, 20s off. The old code drove this with its
-- own per-pack `spawn(function() while pack do ... task.wait(...) end)`
-- loop; here the Play() calls are triggered from the shared tick's phase
-- machine instead (see tickOnce below) - never a per-frame/per-pack loop.
local VALUABLE_HIGHLIGHT_COLOR = Color3.fromRGB(239, 187, 65)
local VALUABLE_FADE_SECONDS = 1
local VALUABLE_HOLD_SECONDS = 6
local VALUABLE_OFF_SECONDS = 20

local function applyHighlyValuableLook(run: Run)
	local pack = run.pack
	if pack == nil then
		return
	end
	local main = pack:FindFirstChild("Main")
	if main == nil or not main:IsA("BasePart") then
		return
	end

	local vfx = ReplicatedFirst:FindFirstChild("VFX")
	local miscEffects = vfx and vfx:FindFirstChild("MiscEffects")
	if miscEffects == nil then
		log:Warn("ReplicatedFirst.VFX.MiscEffects is missing - HighlyValuable has no sparkle/highlight")
		return
	end

	local trueSparkle = miscEffects:FindFirstChild("trueSparkle")
	if trueSparkle then
		local s1 = trueSparkle:Clone()
		s1.Parent = main
	end
	local backAttachment = main:FindFirstChild("BodyBackAttachment")
	if backAttachment then
		local sparkle1 = miscEffects:FindFirstChild("sparkle1")
		if sparkle1 then
			local s2 = sparkle1:Clone()
			s2.Parent = backAttachment
		end
		local sparkle2 = miscEffects:FindFirstChild("sparkle2")
		if sparkle2 then
			local s3 = sparkle2:Clone()
			s3.Parent = backAttachment
		end
	end

	local cancelTemplate = miscEffects:FindFirstChild("Cancel")
	if cancelTemplate and cancelTemplate:IsA("Highlight") then
		local hl = cancelTemplate:Clone() :: Highlight
		hl.FillTransparency = 1
		hl.OutlineTransparency = 1
		hl.FillColor = VALUABLE_HIGHLIGHT_COLOR
		hl.OutlineColor = VALUABLE_HIGHLIGHT_COLOR
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.Adornee = pack
		hl.Parent = pack

		run.valuableHighlight = hl
		run.valuablePhase = "FadeIn"
		run.valuablePhaseEndsAt = Workspace:GetServerTimeNow() + VALUABLE_FADE_SECONDS
		TweenService:Create(hl, TweenInfo.new(VALUABLE_FADE_SECONDS), { FillTransparency = 0.75, OutlineTransparency = 0 }):Play()
	end
end

-- Advances the HighlyValuable pulse's phase machine by exactly one step, if
-- its current phase's timer has elapsed - called from the shared tick, not
-- a per-pack loop.
local function tickValuablePulse(run: Run, now: number)
	local hl = run.valuableHighlight
	if hl == nil or run.valuablePhaseEndsAt == nil or now < run.valuablePhaseEndsAt then
		return
	end

	if run.valuablePhase == "FadeIn" then
		run.valuablePhase = "Hold"
		run.valuablePhaseEndsAt = now + VALUABLE_HOLD_SECONDS
	elseif run.valuablePhase == "Hold" then
		run.valuablePhase = "FadeOut"
		run.valuablePhaseEndsAt = now + VALUABLE_FADE_SECONDS
		TweenService:Create(hl, TweenInfo.new(VALUABLE_FADE_SECONDS), { FillTransparency = 1, OutlineTransparency = 1 }):Play()
	elseif run.valuablePhase == "FadeOut" then
		run.valuablePhase = "Off"
		run.valuablePhaseEndsAt = now + VALUABLE_OFF_SECONDS
	elseif run.valuablePhase == "Off" then
		run.valuablePhase = "FadeIn"
		run.valuablePhaseEndsAt = now + VALUABLE_FADE_SECONDS
		TweenService:Create(hl, TweenInfo.new(VALUABLE_FADE_SECONDS), { FillTransparency = 0.75, OutlineTransparency = 0 }):Play()
	end
end

-- ==================== run lifecycle ====================

local function currentPay(run: Run): number
	return MissionService.ApplyOfferMultiplier(MissionService.CurrentPay(run.baseAmount, run.modifiers, run.failedKeys), run.offerMultiplier)
end

local function sendUpdate(player: Player, run: Run, state: string)
	local payload: { [string]: any } = {
		state = state,
		destination = run.destination,
		destinationPosition = vecToTable(run.destinationPosition),
		modifiers = MissionService.WireModifiers(run.modifiers),
		-- REVIEW-M5C-01B F3: every already-failed key, so the client can
		-- re-grey them on ANY rebuild (most importantly the CourierLoop
		-- return leg's own "Started", which otherwise un-greys a
		-- TimeCrunch/Fragile/VIP that failed on the first leg) without this
		-- ever re-firing the one-shot "ModifierFailed" update itself.
		failed = MissionService.FailedKeysList(run.failedKeys),
		pay = currentPay(run),
	}
	if run.returnPosition then
		payload.returnPosition = vecToTable(run.returnPosition :: Vector3)
	end
	if run.timerEndsAt then
		payload.timerEnds = run.timerEndsAt
	end
	Remotes.Server.Fire("MissionUpdate", player, payload)
end

-- Bryan's refinement: a failed modifier only ever drops its own share of
-- the payout and tells the client which pop-out to grey - it never ends
-- the run (that's still only leaving/dying/respawning/interception/
-- `.mission fail` - see failRun/interceptRun below).
local function failModifier(player: Player, run: Run, key: string)
	if not MissionService.MarkFailed(run.failedKeys, key) then
		return
	end
	Remotes.Server.Fire("MissionUpdate", player, { state = "ModifierFailed", key = key })
	if missionLogEnabled then
		log:Info(string.format("%s's %s modifier failed on their delivery to %s (pay now %d)", player.Name, key, run.destination, currentPay(run)))
	end
end

local function startRun(
	player: Player,
	character: Model,
	originPosition: Vector3,
	destinationKey: string,
	destinationPosition: Vector3,
	modifiers: { ModifierRoll },
	baseAmount: number,
	offerMultiplier: number
)
	local now = Workspace:GetServerTimeNow()
	local hasTimeCrunch = hasModifier(modifiers, "TimeCrunch")
	local hasHighlyValuable = hasModifier(modifiers, "HighlyValuable")

	local run: Run = {
		player = player,
		character = character,
		destination = destinationKey,
		destinationPosition = destinationPosition,
		originPosition = originPosition,
		modifiers = modifiers,
		baseAmount = baseAmount,
		offerMultiplier = offerMultiplier,
		phase = "ToDestination",
		returnPosition = nil,
		hasCourierLoop = hasModifier(modifiers, "CourierLoop"),
		heavyCargo = hasModifier(modifiers, "HeavyCargo"),
		hasFragilePackage = hasModifier(modifiers, "FragilePackage"),
		hasVip = hasModifier(modifiers, "VIP"),
		hasClearTheRoute = hasModifier(modifiers, "CleartheRoute"),
		hasHighlyValuable = hasHighlyValuable,
		clearedRoute = false,
		failedKeys = {},
		preHitFailedKeys = nil,
		timerEndsAt = if hasTimeCrunch then now + Config.Missions.TimeCrunchSeconds else nil,
		startedAt = now,
		pack = attachPackage(character),
		valuableHighlight = nil,
		valuablePhase = nil,
		valuablePhaseEndsAt = nil,
		settled = false,
		-- Bryan's refinement: HighlyValuable's escort stays lit the whole
		-- run - beaconPermanent short-circuits the shared 30s/3s cycle below.
		beaconOn = hasHighlyValuable,
		beaconPermanent = hasHighlyValuable,
		beaconNextAt = now + Config.Missions.Beacon.everySeconds,
		beaconOffAt = nil,
	}

	if run.heavyCargo then
		MovementService.SetModifier(character, "HeavyCargo", Config.Missions.HeavyCargoSpeedMult)
	end
	if run.hasFragilePackage then
		applyFragileLook(run.pack)
	end
	if hasHighlyValuable then
		character:SetAttribute("CourierBeacon", true)
		applyHighlyValuableLook(run)
	end

	runs[player] = run
	runByCharacter[character] = run

	player:SetAttribute("OnMission", true)
	player:SetAttribute("MissionDestination", destinationKey)

	sendUpdate(player, run, "Started")
end

local function cleanupRun(player: Player, run: Run)
	-- Destroys every clone parented under it too - the package, its glass
	-- look, the HighlyValuable sparkles and the pulsing Highlight all live
	-- under `pack` (M6), so nothing needs separate cleanup here.
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

	-- M4: Clear the Route only resolves right here - a knockout could land
	-- at any point up to arrival, so unlike the other three "can fail"
	-- modifiers it can't be marked proactively mid-run.
	if run.hasClearTheRoute and not run.clearedRoute then
		failModifier(player, run, "CleartheRoute")
	end

	local payout = currentPay(run)
	EconomyService.GiveCopperValue(player, payout, string.format("Delivery: %s", run.destination))
	RankService.AddMagoi(player, Config.Missions.MagoiPerDelivery, "Delivery")
	RankService.AddDeed(player, "Gold", 1)

	local data = DataService.Get(player)
	if data then
		MissionService.ApplySuccess(data, run.destination)
		-- The intercepted mark: this delivery already paid at the reduced
		-- rate (`payout` above, via run.offerMultiplier) - now that it's
		-- actually landed, the mark is gone.
		MissionService.ClearIntercepted(data)
		refreshAttributes(player, data)
	end

	sendUpdate(player, run, "Finished")
	cleanupRun(player, run)

	if missionLogEnabled then
		log:Info(string.format("%s delivered to %s for %d Copper", player.Name, run.destination, payout))
	end
end

-- Ends the whole run early with no payout - only ever called for leaving,
-- dying, respawning, an under-the-gate interception attempt, or the dev
-- `.mission fail` command (Bryan's refinement: a failed MODIFIER never
-- reaches here - see failModifier above).
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
-- REVIEW-M5C-01 M2 already gated the CALL to this (CanIntercept) - by the
-- time this runs, the courier was genuinely out on the route.
local function interceptRun(courier: Player, run: Run, attacker: Player)
	if not MissionService.TrySettle(run) then
		return
	end

	-- F4: the pay as it stood BEFORE the knocking blow's own Fragile/VIP
	-- reaction (falling back to the current failedKeys if this interception
	-- didn't come from a real landed hit at all, e.g. a dev `.knock`), and
	-- Clear the Route never counts for an interceptor either way.
	local rawPayout = MissionService.InterceptPay(run.baseAmount, run.modifiers, run.preHitFailedKeys or run.failedKeys)
	-- The intercepted mark: run.offerMultiplier reflects the courier's OWN
	-- stacks as they stood at roll/start time - i.e. before this very
	-- interception's own mark. `.mission mark [n]` CAN still edit
	-- Progress.Intercepted while a run is active (that's the point of the dev
	-- command), but it only ever changes what the NEXT roll/start reads; this
	-- run's own offerMultiplier was captured once, at its start, and never
	-- moves again for it. offerMultiplier < 1 means the courier was ALREADY
	-- marked from an earlier interception (or a `.mission mark`) at that
	-- start: the attacker's payout is reduced the same way a board offer
	-- would be, and (Bryan) no Black Rukh at all while the victim is marked.
	local payout = MissionService.ApplyOfferMultiplier(rawPayout, run.offerMultiplier)
	EconomyService.GiveCopperValue(attacker, payout, string.format("Delivery interception: %s", run.destination))
	if MissionService.InterceptorEarnsBlackRukh(run.offerMultiplier) then
		RankService.AddDeed(attacker, "Black", 1)
	end

	local attackerData = DataService.Get(attacker)
	if attackerData then
		MissionService.ApplyInterception(attackerData, payout)
		refreshAttributes(attacker, attackerData)
	end

	local courierData = DataService.Get(courier)
	if courierData then
		MissionService.ApplyFailure(courierData)
		MissionService.MarkIntercepted(courierData)
		refreshAttributes(courier, courierData)
	end

	sendUpdate(courier, run, "Intercepted")
	cleanupRun(courier, run)

	log:Info(string.format("%s intercepted %s's delivery to %s for %d Copper", attacker.Name, courier.Name, run.destination, payout))
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
	sendBoard(player, board, data)

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

	local data = DataService.Get(player)
	if data == nil then
		return
	end

	-- REVIEW-M5C-01C H1: the intercepted mark as it stands RIGHT NOW, not
	-- whatever it was when this destination was rolled/cached - it can
	-- change while a cache entry sits in boardRolls (a DIFFERENT
	-- destination's run getting intercepted, a clearing delivery, `.mission
	-- mark`), and only this moment (the run actually starting) is what
	-- should fix `run.offerMultiplier` for its whole lifetime.
	local offerMultiplier = MissionService.OfferMultiplier(data.Progress.Intercepted)

	local originPosition = board.part.Position
	closeBoard(player)
	clearCachedRoll(player, destinationKey) -- M3: used up - the next board open re-rolls this destination
	startRun(player, character, originPosition, destinationKey, destPart.Position, dest.modifiers, dest.baseAmount, offerMultiplier)

	if missionLogEnabled then
		log:Info(
			string.format(
				"%s started a delivery from %s to %s (%d Copper)",
				player.Name,
				board.city,
				destinationKey,
				MissionService.PreviewPay(dest.baseAmount, dest.modifiers, offerMultiplier)
			)
		)
	end
end

local function onMissionExit(player: Player)
	local run = runs[player]
	if run then
		failRun(player, run, "left")
	end
	closeBoard(player)
end

-- ==================== interception / Clear the Route credit ====================

local function onStatusChanged(character: Model, status: string, active: boolean)
	if not active or status ~= "Knocked" then
		return
	end

	-- L3: resolved by UserId (CombatService's byUserId), never by name - an
	-- NPC model sharing a name with a real player's username used to be
	-- able to collect someone else's interception payout.
	local info = StatusService.Get(character, "Knocked")
	local byUserId = if info and type(info.data) == "table" then (info.data :: any).byUserId else nil
	local attackerPlayer: Player? = if type(byUserId) == "number" then Players:GetPlayerByUserId(byUserId) else nil

	-- M4: Clear the Route is earned the instant the courier knocks anyone
	-- out, anywhere - independent of whatever's happening to the character
	-- that just got knocked (which might not be on a mission at all).
	if attackerPlayer then
		local attackerRun = runs[attackerPlayer]
		if attackerRun and attackerRun.hasClearTheRoute and not attackerRun.clearedRoute then
			attackerRun.clearedRoute = true
		end
	end

	local run = runByCharacter[character]
	if run == nil then
		return
	end

	if attackerPlayer and attackerPlayer ~= run.player then
		local root = character:FindFirstChild("HumanoidRootPart")
		local distance = if root and root:IsA("BasePart") then (root.Position - run.originPosition).Magnitude else math.huge
		local elapsed = Workspace:GetServerTimeNow() - run.startedAt
		if MissionService.CanIntercept(distance, elapsed) then
			interceptRun(run.player, run, attackerPlayer :: Player)
		else
			failRun(run.player, run, "knocked too close to the start to count as an interception")
		end
	else
		failRun(run.player, run, "knocked")
	end
end

-- M5: FragilePackage/VIP fail on ANY landed hit. CombatService.HitLanded
-- fires for every landed hit (M3-FIX7-S: nothing applies the bridged `Hit`
-- status any more, so this signal is the only hook).
local function onHitLanded(target: Model, _attacker: Model, _hitName: string)
	local run = runByCharacter[target]
	if run == nil then
		return
	end

	-- F4: snapshot BEFORE this hit's own Fragile/VIP react - if this same
	-- hit also knocks the courier out (CombatService fires HitLanded before
	-- the Knocked status, always), interceptRun reads this instead of the
	-- post-hit failedKeys, so the killing blow itself never also costs the
	-- interceptor whatever it just failed for the courier.
	run.preHitFailedKeys = table.clone(run.failedKeys)

	if run.hasFragilePackage then
		failModifier(run.player, run, "FragilePackage")
	end
	if run.hasVip then
		failModifier(run.player, run, "VIP")
	end
end

-- ==================== shared loop (AUDIT H9: no per-frame/per-board loops) ====================

-- Typed as a variadic return (not `()`) so pcall(tickOnce) below
-- type-checks as (boolean, ...any) instead of just (boolean) - same trick
-- Main.server.luau's own ServiceModule type uses for Init/Start.
local function tickOnce(): ...any
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

		-- Bryan's refinement: TimeCrunch expiring only fails ITSELF now -
		-- the run keeps going with a smaller payout, not "Failed".
		if run.timerEndsAt and now >= run.timerEndsAt then
			failModifier(player, run, "TimeCrunch")
			run.timerEndsAt = nil
		end

		-- HighlyValuable: CourierBeacon stays true for the whole run
		-- (Bryan's refinement) - the shared 30s/3s cycle below never
		-- applies to it at all.
		if not run.beaconPermanent then
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
		end

		tickValuablePulse(run, now)

		local root = character:FindFirstChild("HumanoidRootPart")
		if root == nil or not root:IsA("BasePart") then
			continue
		end

		local targetPosition = if run.phase == "ToDestination" then run.destinationPosition else run.originPosition
		if ((root :: BasePart).Position - targetPosition).Magnitude <= Config.Missions.ArriveStuds then
			-- Explicit annotations, not decoration: luau-lsp 1.54.0 widens a
			-- required module's returned union type to plain `string` when
			-- it's read back through a module boundary without one (same
			-- reproduction as RankService.ApplyDeed's own comment).
			local nextPhase: RunPhase?, state: string? = MissionService.OnArrival(run.phase, run.hasCourierLoop)
			if nextPhase and state then
				run.phase = nextPhase
				run.returnPosition = run.originPosition
				sendUpdate(player, run, state)
			else
				finishRun(player, run)
			end
		end
	end
end

-- M1: one error (a destroyed character's SetAttribute, a bad economy call,
-- ...) used to kill this loop for the rest of the server - no arrival,
-- timer, beacon or board-close ever ran again for anyone. Now it's caught
-- and logged, and the loop keeps going next tick.
local function tick()
	local ok, err = pcall(tickOnce)
	if not ok then
		log:Warn(string.format("shared tick errored (recovering next tick): %s", tostring(err)))
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
		table.insert(names, mod.key)
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

	-- A one-off roll, deliberately not routed through the board cache (M3) -
	-- this bypasses the board/proximity check entirely already, same spirit
	-- as every other dev shortcut in this codebase.
	local dest = rollDestination(target, data, cityKey)
	local offerMultiplier = MissionService.OfferMultiplier(data.Progress.Intercepted)

	closeBoard(target)
	startRun(target, character, originPosition, cityKey, destPart.Position, dest.modifiers, dest.baseAmount, offerMultiplier)

	return string.format(
		"%s's delivery to %s started: %d Copper, modifiers: %s",
		target.Name,
		cityKey,
		MissionService.PreviewPay(dest.baseAmount, dest.modifiers, offerMultiplier),
		modNames(dest.modifiers)
	)
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

-- The intercepted mark: shows or sets a player's own stacks directly.
local function missionMarkDevCommand(caller: Player, args: { string }): string
	-- The first token is the stack count only if it parses as a number -
	-- otherwise (or if there's no first token at all) it's the optional
	-- trailing player name and this is a "show" call.
	local maybeN = tonumber(args[1])
	local n: number?, playerArg: string?
	if maybeN ~= nil then
		n = maybeN
		playerArg = args[2]
	else
		playerArg = args[1]
	end

	local target, err = DevService.ResolvePlayer(caller, playerArg)
	if target == nil then
		return err or "player not found"
	end
	local data = DataService.Get(target)
	if data == nil then
		return string.format("%s has no save loaded", target.Name)
	end

	if n == nil then
		return string.format(
			"%s: %d stack(s), offer multiplier %.2f",
			target.Name,
			data.Progress.Intercepted,
			MissionService.OfferMultiplier(data.Progress.Intercepted)
		)
	end

	data.Progress.Intercepted = math.max(0, math.floor(n))
	refreshAttributes(target, data)
	return string.format(
		"%s's intercepted mark set to %d (offer multiplier %.2f)",
		target.Name,
		data.Progress.Intercepted,
		MissionService.OfferMultiplier(data.Progress.Intercepted)
	)
end

-- "Intercepted by nobody": fails the caller's OWN active delivery and adds
-- one stack, with no attacker to pay - so Bryan can test the mark solo,
-- without a second account to actually knock him out.
local function missionInterceptDevCommand(caller: Player, _args: { string }): string
	local run = runs[caller]
	if run == nil then
		return "you have no active delivery"
	end
	local data = DataService.Get(caller)
	if data then
		MissionService.MarkIntercepted(data)
		refreshAttributes(caller, data)
	end
	failRun(caller, run, "dev intercept (marked, no payout - by nobody)")
	return "your delivery was intercepted by nobody: marked, no payout"
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
	elseif sub == "mark" then
		return missionMarkDevCommand(caller, rest)
	elseif sub == "intercept" then
		return missionInterceptDevCommand(caller, rest)
	elseif sub == "log" then
		return missionLogDevCommand(caller, rest)
	end
	return "usage: .mission start <city> [player] | finish [player] | fail [player] | streak <n> [player] | mark [n] [player] | intercept | log on|off"
end

local function registerDevCommands()
	DevService.Register(
		"mission",
		"start <city> [player] | finish [player] | fail [player] | streak <n> [player] | mark [n] [player] | intercept | log on|off - delivery missions",
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
	CombatService.HitLanded:Connect(onHitLanded)

	local function hookPlayer(player: Player)
		player.CharacterRemoving:Connect(function()
			onCharacterRemoving(player)
		end)
		-- L2: Gender resets to 0 on a new life/wipe (CharacterService sets it
		-- non-zero once creation finishes) - the same signal RankService
		-- already uses to know a life just turned over. Refresh whichever
		-- Mission attributes the fresh save now holds either way.
		player:GetAttributeChangedSignal("Gender"):Connect(function()
			local data = DataService.Get(player)
			if data then
				refreshAttributes(player, data)
			end
		end)
	end
	Players.PlayerAdded:Connect(hookPlayer)
	for _, player in Players:GetPlayers() do
		hookPlayer(player)
	end

	-- REVIEW-M5C-01B F1: the ORIGINAL L1 fix here was wrong - DataService's
	-- own PlayerRemoving handler (connected during Init, before this
	-- service's Start ever runs) calls profile:EndSession(), which fires
	-- ProfileStore's own OnSessionEnd SYNCHRONOUSLY and nils
	-- `profiles[player]` before that handler even returns - so a plain
	-- Players.PlayerRemoving connection here, however early it's made,
	-- would already see DataService.Get return nil on every leave, "by
	-- luck" of connection order or not. DataService.OnReleasing (a plain
	-- synchronous callback list, not an event) runs BEFORE EndSession is
	-- ever called, guaranteed regardless of Init/Start ordering - this is
	-- the one place the run is actually failed (and the streak reset) on a
	-- genuine leave; CharacterRemoving already covers the common case
	-- (player had a character), this also catches a charless leave (e.g.
	-- mid-load) that CharacterRemoving would never fire for.
	DataService.OnReleasing(function(player: Player)
		local run = runs[player]
		if run then
			failRun(player, run, "left")
		end
	end)

	-- Local-table cleanup only, unconditional on how the run ended (or
	-- whether there ever was one) - the streak/data side is already fully
	-- handled by OnReleasing above by the time this fires.
	Players.PlayerRemoving:Connect(function(player: Player)
		boards[player] = nil
		boardRolls[player] = nil
		-- Safety net in case OnReleasing's failRun somehow no-op'd.
		local leftover = runs[player]
		if leftover then
			runs[player] = nil
			if runByCharacter[leftover.character] == leftover then
				runByCharacter[leftover.character] = nil
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
