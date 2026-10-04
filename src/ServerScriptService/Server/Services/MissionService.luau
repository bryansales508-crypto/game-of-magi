--!strict
-- Delivery missions. One board per player, opened from a `*Delivery` part. Every
-- start is checked against the board's trade route; modifiers are rolled
-- server-side from the player's own route history and each city's Safety; one
-- shared 0.5s loop handles arrivals, TimeCrunch and the beacon. An interception
-- pays the attacker instantly and exactly once.
--
-- Failing a modifier (TimeCrunch's timer, a FragilePackage/VIP hit, Clear the
-- Route with no knockout) never ends the run: it drops that modifier's share of
-- the payout and sends `MissionUpdate` state "ModifierFailed" `{key}` so the
-- client greys the pop-out. Only leaving, dying, respawning, an interception, or
-- `.mission fail` end a run early.
--
-- The gold Highlight lives on the package only; the HighlyValuable courier gets
-- the same occasional beacon as every other courier.

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
local BountyService = require(script.Parent.BountyService)
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

-- Pure: whether `destinationKey` is on `cityKey`'s trade route. Used as the
-- remote handler's guard and by the dev `.mission start`.
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

-- Pure: the roll factors for one destination, from the player's own save
-- (Progress.Routes) and the city's static Safety.
function MissionService.FactorsFor(data: Data, destinationKey: string): Cities.Factors
	local city = Cities.ByKey[destinationKey]
	local safety = if city then city.safety else 0
	local timesRun = data.Progress.Routes[destinationKey] or 0
	return {
		PlayerActive = timesRun > Config.Missions.PlayerActiveThreshold,
		SafeRoute = safety > Config.Missions.SafeRouteThreshold,
	}
end

-- Pure: the pre-multiplier base amount (rank/population/streak only, no
-- modifiers). Cached per board roll and combined with the still-intact modifiers
-- at settlement (CurrentPay), so a mid-run failure only lowers the payout.
-- Ranks.rankFor never returns less than 1, so 10/rankIndex cannot divide by zero.
function MissionService.BaseAmount(rankIndex: number, population: number, streak: number): number
	return math.floor(1 + 10 / rankIndex + population * 1.25 + streak * 1.25)
end

-- Pure: base amount times the modifiers' combined multiplier for a fixed set of
-- modifiers; used for the board preview (every modifier intact) and the
-- self-test. Cities.CombinedMultiplier is additive, not a product.
function MissionService.ComputePay(rankIndex: number, population: number, streak: number, modifiers: { ModifierRoll }): number
	return math.floor(MissionService.BaseAmount(rankIndex, population, streak) * Cities.CombinedMultiplier(modifiers))
end

-- Pure: the payout at settlement: `baseAmount` combined with the rolled modifiers
-- not listed in `failedKeys`.
function MissionService.CurrentPay(baseAmount: number, modifiers: { ModifierRoll }, failedKeys: { [string]: boolean }): number
	local intact: { ModifierRoll } = {}
	for _, mod in modifiers do
		if not failedKeys[mod.key] then
			table.insert(intact, mod)
		end
	end
	return math.floor(baseAmount * Cities.CombinedMultiplier(intact))
end

-- Pure: what an interceptor is paid. `failedKeysBeforeHit` is the failed set
-- before the hit that knocked the courier out, so the killing blow never costs
-- the interceptor what it just failed for the courier. Clear the Route's bonus is
-- always excluded.
function MissionService.InterceptPay(baseAmount: number, modifiers: { ModifierRoll }, failedKeysBeforeHit: { [string]: boolean }): number
	local excluding: { [string]: boolean } = table.clone(failedKeysBeforeHit)
	excluding["CleartheRoute"] = true
	return MissionService.CurrentPay(baseAmount, modifiers, excluding)
end

-- Pure: the multiplier earned by `stacks` interception marks on the courier:
-- halved per stack with a 10% floor. Applies to their board offers, their own
-- payout, and an interceptor's payout while the victim is marked. `stacks == 0`
-- is exactly 1.
function MissionService.OfferMultiplier(stacks: number): number
	return math.max(Config.Missions.InterceptedFloor, Config.Missions.InterceptedDecay ^ stacks)
end

-- Pure: applies an OfferMultiplier to a computed pay number. Kept separate so
-- ComputePay/CurrentPay/InterceptPay do not know about the mark.
function MissionService.ApplyOfferMultiplier(pay: number, offerMultiplier: number): number
	return math.floor(pay * offerMultiplier)
end

-- Pure: board-preview pay for a cached `BoardDestination`. Applies
-- `offerMultiplier` fresh on every call because the mark can change while the
-- roll sits in `boardRolls`. No modifier is pre-failed.
function MissionService.PreviewPay(baseAmount: number, modifiers: { ModifierRoll }, offerMultiplier: number): number
	return MissionService.ApplyOfferMultiplier(MissionService.CurrentPay(baseAmount, modifiers, {}), offerMultiplier)
end

-- Pure: the courier's mark advances by one per interception; only
-- ClearIntercepted removes it.
function MissionService.MarkIntercepted(data: Data)
	data.Progress.Intercepted += 1
end

-- Pure: a completed delivery clears the mark, after being paid at the rate rolled
-- for it.
function MissionService.ClearIntercepted(data: Data)
	data.Progress.Intercepted = 0
end

-- Pure: an interceptor earns a Black Rukh only if the victim was not already
-- marked; `offerMultiplierAtStart` is the run's own offerMultiplier, exactly 1
-- only when stacks was 0.
function MissionService.InterceptorEarnsBlackRukh(offerMultiplierAtStart: number): boolean
	return offerMultiplierAtStart >= 1
end

-- Pure: marks a modifier failed in `failedKeys`; returns true only the first
-- time, so the ModifierFailed update fires once per modifier per run.
function MissionService.MarkFailed(failedKeys: { [string]: boolean }, key: string): boolean
	if failedKeys[key] then
		return false
	end
	failedKeys[key] = true
	return true
end

-- Pure: the failed-keys set as an array for the wire. Every MissionUpdate carries
-- it so the client can re-grey failed pop-outs on any rebuild (e.g. the
-- CourierLoop return leg's "Started").
function MissionService.FailedKeysList(failedKeys: { [string]: boolean }): { string }
	local list: { string } = {}
	for key in failedKeys do
		table.insert(list, key)
	end
	return list
end

-- Pure: phase transition on arrival. "Returning" with a "Started" update loops
-- back (CourierLoop); the client re-arms its tracker only on "Started" with
-- `returnPosition` set and tears the run down on any other state. `nil` means the
-- run is done (finishRun decides).
function MissionService.OnArrival(phase: RunPhase, hasCourierLoop: boolean): (RunPhase?, string?)
	if phase == "ToDestination" and hasCourierLoop then
		return "Returning", "Started"
	end
	return nil, nil
end

-- Pure: an interception only pays if the courier is out on the route
-- (distance/time gate, Config.Missions.InterceptMin*), so accounts cannot farm by
-- knocking out a courier next to the board.
function MissionService.CanIntercept(distanceFromOrigin: number, elapsedSeconds: number): boolean
	return distanceFromOrigin >= Config.Missions.InterceptMinStuds or elapsedSeconds >= Config.Missions.InterceptMinSeconds
end

-- Pure: board-roll cache get-or-roll. `roll` runs only on a miss; a hit returns
-- the same table until a run to that destination starts and clears the entry.
function MissionService.GetOrRoll<T>(cache: { [string]: T }, key: string, roll: () -> T): T
	local cached = cache[key]
	if cached ~= nil then
		return cached
	end
	local entry = roll()
	cache[key] = entry
	return entry
end

-- Pure: a run settles (pays, fails or is intercepted) exactly once; later callers
-- see `settled` already true and do nothing. A failed modifier never settles the
-- run.
export type SettleState = { settled: boolean }
function MissionService.TrySettle(state: SettleState): boolean
	if state.settled then
		return false
	end
	state.settled = true
	return true
end

-- Pure: a completed delivery updates the saved streak and per-city route history.
function MissionService.ApplySuccess(data: Data, destinationKey: string)
	data.Progress.DeliveryStreak += 1
	data.Progress.Routes[destinationKey] = (data.Progress.Routes[destinationKey] or 0) + 1
end

-- Pure: any failed/intercepted run breaks the streak; route history is only
-- earned on delivery.
function MissionService.ApplyFailure(data: Data)
	data.Progress.DeliveryStreak = 0
end

-- ==================== runtime types ====================

-- Carries no offerMultiplier/pay: the intercepted mark can change while the entry
-- sits in `boardRolls`, so PreviewPay applies the current multiplier on every
-- read.
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

type ValuablePulsePhase = "FadeIn" | "Hold"

type Run = {
	player: Player,
	character: Model,
	destination: string,
	destinationPosition: Vector3,
	originPosition: Vector3,
	modifiers: { ModifierRoll }, -- the full rolled set, immutable through the run
	baseAmount: number,
	offerMultiplier: number, -- the intercepted mark, fixed at roll time
	phase: RunPhase,
	returnPosition: Vector3?,
	hasCourierLoop: boolean,
	heavyCargo: boolean,
	hasFragilePackage: boolean,
	hasVip: boolean,
	hasClearTheRoute: boolean,
	hasHighlyValuable: boolean,
	clearedRoute: boolean, -- earned a knockout during the run
	failedKeys: { [string]: boolean }, -- dropped from the payout, run continues
	-- failedKeys as it stood before the hit that knocked the courier out; nil
	-- until the first landed hit (interceptRun falls back to failedKeys).
	preHitFailedKeys: { [string]: boolean }?,
	timerEndsAt: number?, -- Workspace:GetServerTimeNow(), also the wire value
	startedAt: number, -- for the interception elapsed-time gate
	pack: Instance?,
	valuableHighlight: Highlight?,
	valuablePhase: ValuablePulsePhase?,
	valuablePhaseEndsAt: number?,
	settled: boolean,
	beaconOn: boolean,
	beaconNextAt: number,
	beaconOffAt: number?,
}

-- ==================== state ====================
-- Keyed by Player/Model, never by name.

local boards: { [Player]: Board } = {}
-- Cached per player per destination key across board opens; cleared when a run to
-- that destination starts (clearCachedRoll).
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

-- A city with no `<key>Delivery` part gets a server-side placeholder so every
-- route can be tested. Position: centre of `<key>REGION` under Workspace.Regions
-- (dropped to the ground when a raycast hits), else
-- Config.Missions.PlaceholderDeliveryPoints, else nil (run refused).
local PLACEHOLDER_SUFFIX = "_PLACEHOLDER"
local PLACEHOLDER_COLOR = Color3.fromRGB(255, 0, 200)
local placeholderLogged: { [string]: boolean } = {}

-- Pure: the region part's centre, else the configured point, else nil.
function MissionService.PlaceholderPosition(cityKey: string, regionPart: BasePart?): Vector3?
	if regionPart then
		return regionPart.Position
	end
	return Config.Missions.PlaceholderDeliveryPoints[cityKey]
end

local function groundBelow(position: Vector3, regionPart: BasePart): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { regionPart }
	local top = Vector3.new(position.X, position.Y + regionPart.Size.Y / 2, position.Z)
	local hit = Workspace:Raycast(top, Vector3.new(0, -(regionPart.Size.Y + 1000), 0), params)
	if hit then
		return hit.Position + Vector3.new(0, 3, 0)
	end
	return position
end

-- The part a city's deliveries go to: the real part under `parent` if present,
-- else the placeholder (reused or created), else nil.
function MissionService.ResolveDeliveryPart(cityKey: string, parent: Instance): BasePart?
	local name = Cities.DeliveryPartName(cityKey)
	local real = parent:FindFirstChild(name)
	if real and real:IsA("BasePart") then
		return real
	end

	local existing = parent:FindFirstChild(name .. PLACEHOLDER_SUFFIX)
	if existing and existing:IsA("BasePart") then
		return existing
	end

	local regionPart = BountyService.FindRegionPart(cityKey)
	local position = MissionService.PlaceholderPosition(cityKey, regionPart)
	if position == nil then
		return nil
	end
	if regionPart then
		position = groundBelow(position, regionPart)
	end

	local placeholder = Instance.new("Part")
	placeholder.Name = name .. PLACEHOLDER_SUFFIX
	placeholder.Size = Vector3.new(8, 8, 8)
	placeholder.Shape = Enum.PartType.Ball
	placeholder.Anchored = true
	placeholder.CanCollide = false
	placeholder.CanTouch = false
	placeholder.CanQuery = false
	placeholder.Color = PLACEHOLDER_COLOR
	placeholder.Material = Enum.Material.Neon
	placeholder.Transparency = 0.5
	placeholder.Position = position
	placeholder.Parent = parent

	if not placeholderLogged[cityKey] then
		placeholderLogged[cityKey] = true
		log:Warn(string.format("Workspace.MAP.MISSION.%s is missing - using a placeholder drop-off for %s at %s", name, cityKey, tostring(position)))
	end
	return placeholder
end

-- Placeholders live in their own server-made folder, never in the real map.
local PLACEHOLDER_FOLDER_NAME = "MissionPlaceholders"

local function placeholderFolder(): Folder
	local folder = Workspace:FindFirstChild(PLACEHOLDER_FOLDER_NAME)
	if folder and folder:IsA("Folder") then
		return folder
	end
	if folder then
		folder:Destroy()
	end
	local created = Instance.new("Folder")
	created.Name = PLACEHOLDER_FOLDER_NAME
	created.Parent = Workspace
	return created
end

-- On Start: removes every `*_PLACEHOLDER` part anywhere under Workspace and
-- the whole MissionPlaceholders folder, so a stale one saved into the place
-- can never shadow a real part. Returns how many were removed.
function MissionService.SweepPlaceholders(root: Instance): number
	local removed = 0
	for _, inst in root:GetDescendants() do
		if inst:IsA("BasePart") and inst.Name:sub(-#PLACEHOLDER_SUFFIX) == PLACEHOLDER_SUFFIX then
			inst:Destroy()
			removed += 1
		end
	end
	local folder = root:FindFirstChild(PLACEHOLDER_FOLDER_NAME)
	if folder then
		removed += #folder:GetChildren()
		folder:Destroy()
	end
	return removed
end

local function getDeliveryPart(cityKey: string): BasePart?
	local map = Workspace:FindFirstChild("MAP")
	local missionFolder = map and map:FindFirstChild("MISSION")
	local real = missionFolder and missionFolder:FindFirstChild(Cities.DeliveryPartName(cityKey))
	if real and real:IsA("BasePart") then
		return real
	end
	return MissionService.ResolveDeliveryPart(cityKey, placeholderFolder())
end

-- The one place a city key becomes a world position: its `<key>Delivery` part or
-- placeholder. A city with neither is logged once and the caller refuses the run.
local missingPartLogged: { [string]: boolean } = {}

function MissionService.DestinationPositionFor(cityKey: string): Vector3?
	local part = getDeliveryPart(cityKey)
	if part == nil then
		if not missingPartLogged[cityKey] then
			missingPartLogged[cityKey] = true
			log:Warn(string.format("Workspace.MAP.MISSION.%s is missing and no placeholder point exists - refusing deliveries to %s", Cities.DeliveryPartName(cityKey), cityKey))
		end
		return nil
	end
	return part.Position
end

-- ==================== attributes ====================

local function initAttributes(player: Player)
	player:SetAttribute("OnMission", false)
	player:SetAttribute("MissionDestination", "")
end

local function refreshAttributes(player: Player, data: Data)
	player:SetAttribute("MissionStreak", data.Progress.DeliveryStreak)
end

-- ==================== board ====================

local function closeBoard(player: Player)
	if boards[player] == nil then
		return
	end
	boards[player] = nil
	Remotes.Server.Fire("MissionBoard", player, nil)
end

-- Pure: every modifier sent to the client is `{ key, name, chance, text }`: `key`
-- is the internal name (a ModifierFailed update's `key` matches it) and `name`
-- the display name, which the client's pop-out titles and Time Crunch/Courier
-- Loop special-cases match on.
function MissionService.WireModifiers(modifiers: { ModifierRoll }): { any }
	local list = {}
	for _, mod in modifiers do
		table.insert(list, { key = mod.key, name = mod.displayName, chance = mod.chance, text = mod.text })
	end
	return list
end

local function sendBoard(player: Player, board: Board, data: Data)
	-- Computed fresh from the current save: the intercepted mark is not cached
	-- with the roll.
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
	-- Board headline: the player's current stack count and what it is worth, the
	-- same multiplier the destination pays were computed with.
	Remotes.Server.Fire("MissionBoard", player, {
		city = board.city,
		destinations = destinationsPayload,
		intercepted = data.Progress.Intercepted,
		offerMultiplier = offerMultiplier,
	})
end

-- Rolls one destination fresh; getOrRollDestination owns the caching.
local function rollDestination(player: Player, data: Data, destKey: string): BoardDestination
	local rankIndex = select(1, RankService.GetRank(player))
	local population = #Players:GetPlayers()
	local streak = data.Progress.DeliveryStreak
	local factors = MissionService.FactorsFor(data, destKey)
	local modifiers = Cities.RollModifiers(factors, rollDie)
	local baseAmount = MissionService.BaseAmount(rankIndex, population, streak)
	return { key = destKey, modifiers = modifiers, baseAmount = baseAmount }
end

-- Reuses a player's cached roll for `destKey`, so reopening the board cannot be
-- used to fish for VIP/HighlyValuable.
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

-- The roll is used up when a run to it starts; the next board open rolls it
-- fresh.
local function clearCachedRoll(player: Player, destKey: string)
	local cache = boardRolls[player]
	if cache then
		cache[destKey] = nil
	end
end

-- Builds a board from cached (or freshly rolled) destinations on the route. The
-- dev `.mission start` rolls its own one-off instead.
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

-- ReplicatedFirst.Objects/VFX are not synced by Rojo (Studio-only art); missing
-- art degrades gracefully (no visible package or look) instead of erroring.

local PACKAGE_TEMPLATE_NAMES = { "Package1", "Package2" }

-- Pure: the model scale for a package (HeavyCargo draws it bigger by
-- Config.Missions.HeavyCargoPackScale) and a torso-space offset scaled to match,
-- so a bigger pack sits on the back, not in it.
function MissionService.PackScale(heavyCargo: boolean): number
	return if heavyCargo then Config.Missions.HeavyCargoPackScale else 1
end

function MissionService.ScaledOffset(offset: number, scale: number): number
	return offset * scale
end

-- Pure: the courier's beacon schedule at run start: off, first pulse after the
-- ordinary interval, same for every courier.
function MissionService.InitialBeacon(now: number): (boolean, number)
	return false, now + Config.Missions.Beacon.everySeconds
end

local function attachPackage(character: Model, heavyCargo: boolean): Instance?
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
	local scale = MissionService.PackScale(heavyCargo)
	if scale ~= 1 then
		pack:ScaleTo(pack:GetScale() * scale)
	end
	local primary = pack.PrimaryPart
	if primary == nil then
		pack:Destroy()
		return nil
	end
	primary.CFrame = torso.CFrame

	local main = pack:FindFirstChild("Main")
	if main and main:IsA("BasePart") then
		if pack:FindFirstChild("Pack1") then
			main.CFrame = torso.CFrame:ToWorldSpace(CFrame.new(0, 0, MissionService.ScaledOffset(0.3, scale)) * CFrame.Angles(0, math.rad(180), 0))
		elseif pack:FindFirstChild("Pack2") then
			main.CFrame = torso.CFrame:ToWorldSpace(CFrame.new(0, 0, MissionService.ScaledOffset(1.25, scale)) * CFrame.Angles(math.rad(270), math.rad(90), math.rad(90)))
		end
	end

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = primary
	weld.Part1 = torso
	weld.Parent = pack

	pack.Parent = character
	return pack
end

-- Turns the pack to glass. Cosmetic; not reverted when the modifier fails.
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

-- HighlyValuable look: sparkle VFX plus a gold Highlight on the pack, driven by
-- the shared tick's phase machine (tickOnce), not a per-pack loop.
local VALUABLE_HIGHLIGHT_COLOR = Color3.fromRGB(239, 187, 65)
local VALUABLE_FADE_SECONDS = 1

-- Returns the gold Highlight (parented to the package, never the character),
-- or nil if the art is missing; the caller stores it for the pulse machine.
function MissionService.ApplyHighlyValuableLook(pack: Instance?): Highlight?
	if pack == nil then
		return nil
	end
	local main = pack:FindFirstChild("Main")
	if main == nil or not main:IsA("BasePart") then
		return nil
	end

	local vfx = ReplicatedFirst:FindFirstChild("VFX")
	local miscEffects = vfx and vfx:FindFirstChild("MiscEffects")
	if miscEffects == nil then
		log:Warn("ReplicatedFirst.VFX.MiscEffects is missing - HighlyValuable has no sparkle/highlight")
		return nil
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

		TweenService:Create(hl, TweenInfo.new(VALUABLE_FADE_SECONDS), { FillTransparency = 0.75, OutlineTransparency = 0 }):Play()
		return hl
	end
	return nil
end

-- Advances the HighlyValuable pulse phase machine by one step if its timer
-- elapsed; called from the shared tick.
local function tickValuablePulse(run: Run, now: number)
	local hl = run.valuableHighlight
	if hl == nil or run.valuablePhaseEndsAt == nil or now < run.valuablePhaseEndsAt then
		return
	end

	-- The package glow fades in once and holds for the whole run.
	if run.valuablePhase == "FadeIn" then
		run.valuablePhase = "Hold"
		run.valuablePhaseEndsAt = nil
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
		-- Every already-failed key, so the client can re-grey them on any rebuild
		-- without re-firing ModifierFailed.
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

-- A failed modifier drops its share of the payout and greys the client's pop-out;
-- it never ends the run (see failRun/interceptRun).
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

	local beaconOn, beaconNextAt = MissionService.InitialBeacon(now)

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
		pack = attachPackage(character, hasModifier(modifiers, "HeavyCargo")),
		valuableHighlight = nil,
		valuablePhase = nil,
		valuablePhaseEndsAt = nil,
		settled = false,
		beaconOn = beaconOn,
		beaconNextAt = beaconNextAt,
		beaconOffAt = nil,
	}

	if run.heavyCargo then
		MovementService.SetModifier(character, "HeavyCargo", Config.Missions.HeavyCargoSpeedMult)
	end
	if run.hasFragilePackage then
		applyFragileLook(run.pack)
	end
	if hasHighlyValuable then
		local hl = MissionService.ApplyHighlyValuableLook(run.pack)
		if hl then
			run.valuableHighlight = hl
			run.valuablePhase = "FadeIn"
			run.valuablePhaseEndsAt = Workspace:GetServerTimeNow() + VALUABLE_FADE_SECONDS
		end
	end

	runs[player] = run
	runByCharacter[character] = run

	player:SetAttribute("OnMission", true)
	player:SetAttribute("MissionDestination", destinationKey)

	sendUpdate(player, run, "Started")
end

local function cleanupRun(player: Player, run: Run)
	-- Destroys every clone parented under it: the package, its glass look,
	-- sparkles and Highlight all live under `pack`.
	if run.pack then
		run.pack:Destroy()
	end
	-- Cleared on any end of the run.
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

	-- Clear the Route resolves only here: a knockout can land any time up to
	-- arrival, so it cannot be marked proactively.
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
		-- This delivery paid at the reduced rate; now the mark is gone.
		MissionService.ClearIntercepted(data)
		refreshAttributes(player, data)
	end

	sendUpdate(player, run, "Finished")
	cleanupRun(player, run)

	if missionLogEnabled then
		log:Info(string.format("%s delivered to %s for %d Copper", player.Name, run.destination, payout))
	end
end

-- Ends the run early with no payout: leaving, dying, respawning, a disqualifying
-- interception attempt, or the dev `.mission fail`. A failed modifier never
-- reaches here.
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

-- The attacker is paid the run's full reward instantly, exactly once (TrySettle);
-- the courier's wallet is never touched. CanIntercept already gated the call.
local function interceptRun(courier: Player, run: Run, attacker: Player)
	if not MissionService.TrySettle(run) then
		return
	end

	-- Pay as it stood before the knocking blow's own Fragile/VIP reaction
	-- (current failedKeys if the interception was not from a landed hit, e.g. dev
	-- `.knock`); Clear the Route never counts for an interceptor.
	local rawPayout = MissionService.InterceptPay(run.baseAmount, run.modifiers, run.preHitFailedKeys or run.failedKeys)
	-- run.offerMultiplier was captured at run start and never changes, even if
	-- `.mission mark` edits Progress.Intercepted. Below 1 means the courier was
	-- already marked: the attacker's payout is reduced like a board offer and no
	-- Black Rukh is awarded.
	local payout = MissionService.ApplyOfferMultiplier(rawPayout, run.offerMultiplier)
	EconomyService.GiveCopperValue(attacker, payout, string.format("Delivery interception: %s", run.destination))
	if MissionService.InterceptorEarnsBlackRukh(run.offerMultiplier) then
		RankService.AddDeed(attacker, "Black", 1)
	end

	-- The interceptor's reward is also their crime: it goes on their bounty. The courier's own
	-- copper is never reduced.
	BountyService.Add(attacker, payout, string.format("Delivery interception: %s", run.destination))

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
	-- A prisoner runs no deliveries.
	local prisoner = player.Character
	if prisoner and StatusService.Has(prisoner, "Jailed") then
		return
	end
	local dest = board.destinations[destinationKey]
	-- Rejected unless the destination is on this board's own route
	-- (Validate.string only rejects nonsense strings).
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

	local destinationPosition = MissionService.DestinationPositionFor(destinationKey)
	if destinationPosition == nil then
		return
	end

	local data = DataService.Get(player)
	if data == nil then
		return
	end

	-- The intercepted mark as it is now, not as cached at roll time; it fixes
	-- run.offerMultiplier for the run.
	local offerMultiplier = MissionService.OfferMultiplier(data.Progress.Intercepted)

	local originPosition = board.part.Position
	closeBoard(player)
	clearCachedRoll(player, destinationKey) -- used up: next board open re-rolls this destination
	startRun(player, character, originPosition, destinationKey, destinationPosition, dest.modifiers, dest.baseAmount, offerMultiplier)

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

	-- Resolved by UserId (CombatService's byUserId), never by name, so an NPC
	-- sharing a player's name cannot collect their payout.
	local info = StatusService.Get(character, "Knocked")
	local byUserId = if info and type(info.data) == "table" then (info.data :: any).byUserId else nil
	local attackerPlayer: Player? = if type(byUserId) == "number" then Players:GetPlayerByUserId(byUserId) else nil

	-- Clear the Route is earned the instant the courier knocks anyone out,
	-- regardless of the knocked character's mission state.
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

-- FragilePackage/VIP fail on any landed hit; CombatService.HitLanded is the only
-- hook.
local function onHitLanded(target: Model, _attacker: Model, _hitName: string)
	local run = runByCharacter[target]
	if run == nil then
		return
	end

	-- Snapshot before this hit's own Fragile/VIP reaction (HitLanded fires before
	-- Knocked), so interceptRun can exclude it from the interceptor's pay.
	run.preHitFailedKeys = table.clone(run.failedKeys)

	if run.hasFragilePackage then
		failModifier(run.player, run, "FragilePackage")
	end
	if run.hasVip then
		failModifier(run.player, run, "VIP")
	end
end

-- ==================== shared loop ====================

-- Typed as a variadic return (not `()`) so pcall(tickOnce) type-checks as
-- (boolean, ...any).
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
			-- CharacterRemoving normally fails the run; this catches an ordering
			-- edge case.
			failRun(player, run, "respawn")
			continue
		end

		-- TimeCrunch expiring fails only itself; the run continues.
		if run.timerEndsAt and now >= run.timerEndsAt then
			failModifier(player, run, "TimeCrunch")
			run.timerEndsAt = nil
		end

		-- The shared occasional beacon (every courier, HighlyValuable too).
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

		tickValuablePulse(run, now)

		local root = character:FindFirstChild("HumanoidRootPart")
		if root == nil or not root:IsA("BasePart") then
			continue
		end

		local targetPosition = if run.phase == "ToDestination" then run.destinationPosition else run.originPosition
		if ((root :: BasePart).Position - targetPosition).Magnitude <= Config.Missions.ArriveStuds then
			-- Explicit annotations: luau-lsp widens a required module's returned
			-- union type to `string` across a module boundary without them.
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

-- One error (e.g. a destroyed character's SetAttribute) must not kill the loop
-- for everyone, so each tick is caught and logged.
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
	local destinationPosition = MissionService.DestinationPositionFor(cityKey)
	if destinationPosition == nil then
		return string.format("Workspace.MAP.MISSION.%s is missing", Cities.DeliveryPartName(cityKey))
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	local originPosition = if root and root:IsA("BasePart") then (root :: BasePart).Position else destinationPosition

	-- A one-off roll, deliberately bypassing the board cache and proximity check.
	local dest = rollDestination(target, data, cityKey)
	local offerMultiplier = MissionService.OfferMultiplier(data.Progress.Intercepted)

	closeBoard(target)
	startRun(target, character, originPosition, cityKey, destinationPosition, dest.modifiers, dest.baseAmount, offerMultiplier)

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

-- Shows or sets a player's own intercepted stacks.
local function missionMarkDevCommand(caller: Player, args: { string }): string
	-- The first token is the stack count if it parses as a number; otherwise it
	-- is the optional player name and this is a show call.
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

-- Fails the caller's own active delivery and adds one stack, with no attacker, to
-- test the mark solo.
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

-- Dispatches ".mission <sub> ..." to the handler above.
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
	local swept = MissionService.SweepPlaceholders(Workspace)
	if swept > 0 then
		log:Info(string.format("Swept %d stale delivery placeholder(s) on start", swept))
	end
	Remotes.Server.On("MissionOpenBoard", onOpenBoard)
	Remotes.Server.On("MissionStart", onMissionStart)
	Remotes.Server.On("MissionExit", onMissionExit)

	StatusService.Changed:Connect(onStatusChanged)
	CombatService.HitLanded:Connect(onHitLanded)

	local function hookPlayer(player: Player)
		player.CharacterRemoving:Connect(function()
			onCharacterRemoving(player)
		end)
		-- Gender resets to 0 on a new life (CharacterService sets it non-zero
		-- after creation); refresh the Mission attributes from the fresh save.
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

	-- DataService.OnReleasing runs before EndSession nils the profile, so it is
	-- the one reliable place to fail the run (and reset the streak) on a leave,
	-- including a charless leave CharacterRemoving never covers. A plain
	-- PlayerRemoving connection would already see DataService.Get return nil.
	DataService.OnReleasing(function(player: Player)
		local run = runs[player]
		if run then
			failRun(player, run, "left")
		end
	end)

	-- Local-table cleanup only; the streak/data side was handled by OnReleasing.
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
