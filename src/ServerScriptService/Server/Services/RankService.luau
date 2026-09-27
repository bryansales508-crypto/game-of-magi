--!strict
-- Rank, Rukh alignment and epithets (M4-01, DESIGN.md section 3a). Computes
-- each player's rank/alignment from Progress (Magoi/GoldRukh/BlackRukh),
-- owns the Rank/RankIndex/Epithet/Alignment/EpithetPending attributes
-- (taken over from HealthService's old per-tick refresh - see HealthService's
-- own M4-01 comment), and fires the rank-up/alignment-changed moments and
-- the origin epithet choice at birth.
--
-- A rank-up never overwrites a choice that's still pending, and never skips
-- straight to the top rank when one grant crosses several thresholds at
-- once: NextRankToAnnounce/NextRankAfterChoice walk the player forward one
-- rank at a time, the origin choice always first (H1 fix, REVIEW-M4-01).
--
-- No shared polling loop: every Progress mutation goes through AddMagoi/
-- AddDeed (including the dev `.magoi`/`.magoi+`/`.rukh` commands, re-
-- registered below to route through them - DevService.Register overwrites
-- its own built-in entries by name, the same public extension point
-- AgeService/HealthService already use to ADD commands), so the rank/
-- alignment check runs right where the number actually changes instead of
-- up to a tick late.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local SaveSchema = require(ReplicatedStorage.Shared.SaveSchema)
local Ranks = require(ReplicatedStorage.Shared.Data.Ranks)
local Alignment = require(ReplicatedStorage.Shared.Data.Alignment)
local Epithets = require(ReplicatedStorage.Shared.Data.Epithets)
local DataService = require(script.Parent.DataService)
local LegacyBridge = require(script.Parent.LegacyBridge)
local DevService = require(script.Parent.DevService)

local log = Log.new("RankService")

type Data = SaveSchema.Data
type DeedKind = "Gold" | "Black"
-- A local alias for the qualified external type (same idiom Epithets.luau
-- uses for its own AlignmentKey), rather than writing Alignment.Alignment
-- at every call site.
type RukhAlignment = Alignment.Alignment

local RankService = {}

-- ==================== pure helpers (self-tested directly) ====================

-- Ranks.titleFor takes a Magoi amount, not a rank index; this resolves a
-- known index (e.g. from a stored PendingEpithet) to its gendered title by
-- feeding back that rank's own threshold, which always resolves to the same
-- index (rankFor picks the highest threshold at or below the given amount).
function RankService.TitleForIndex(index: number, gender: number): string
	return Ranks.titleFor(Ranks.List[index].magoi, gender)
end

-- Pure: mutates data.Progress.Magoi by `amount` (clamped at 0) and returns
-- the rank index before and after, so a caller - or a self-test, with a
-- fake Data table and no Player/DataService at all - can decide whether
-- this crossed a rank threshold.
function RankService.ApplyMagoi(data: Data, amount: number): (number, number)
	local oldIndex = (Ranks.rankFor(data.Progress.Magoi))
	data.Progress.Magoi = math.max(0, data.Progress.Magoi + amount)
	local newIndex = (Ranks.rankFor(data.Progress.Magoi))
	return oldIndex, newIndex
end

-- Pure: same shape as ApplyMagoi, for one Rukh tally.
function RankService.ApplyDeed(data: Data, kind: DeedKind, amount: number): (RukhAlignment, RukhAlignment)
	-- The `: RukhAlignment` annotations below are needed, not decorative:
	-- luau-lsp 1.54.0 widens Alignment.alignmentFor's return to plain
	-- `string` when it's read back through a second module boundary with a
	-- `::` cast (a real reproduction, not a guess); a `local x: T = expr`
	-- declaration doesn't have the same problem, so that's the form used
	-- here instead.
	local oldAlignment: RukhAlignment = Alignment.alignmentFor(data.Progress.GoldRukh, data.Progress.BlackRukh)
	if kind == "Gold" then
		data.Progress.GoldRukh = math.max(0, data.Progress.GoldRukh + amount)
	else
		data.Progress.BlackRukh = math.max(0, data.Progress.BlackRukh + amount)
	end
	local newAlignment: RukhAlignment = Alignment.alignmentFor(data.Progress.GoldRukh, data.Progress.BlackRukh)
	return oldAlignment, newAlignment
end

-- Pure: applies a ChooseEpithet(index) request against `data` directly.
-- Returns (true) on success, or (false, reason) if there's nothing pending
-- or index is out of range - the remote's own validator (Shared/Remotes.luau)
-- already guarantees an in-range integer, so the range check here is
-- defense in depth (and a fake Data table for the self-test), not the only
-- guard.
function RankService.ApplyChooseEpithet(data: Data, index: number): (boolean, string?)
	local pending = data.Progress.PendingEpithet
	if pending == nil then
		return false, "no epithet is pending"
	end
	if index ~= math.floor(index) or index < 1 or index > 3 then
		return false, "index out of range"
	end
	local choice = pending.choices[index]
	if choice == nil then
		return false, "index out of range"
	end

	data.Progress.Epithet = choice
	data.Progress.PendingEpithet = nil
	return true
end

-- Pure: whether a life should be offered its origin epithet choice - only
-- once character creation is actually done (a nonzero Gender) and nothing
-- has been chosen or is already pending.
function RankService.ShouldOfferOrigin(data: Data, gender: number): boolean
	return data.Progress.Epithet == "" and data.Progress.PendingEpithet == nil and gender ~= 0
end

-- Pure (H1 fix, REVIEW-M4-01): decides which rank, if any, AddMagoi should
-- announce right after an ApplyMagoi call. Never overwrites a choice
-- that's still pending (nil while one is), never announces before the
-- origin epithet exists (Epithet == "" - it always comes first), and never
-- jumps past oldIndex + 1 even if `amount` crossed several thresholds at
-- once - RankService.NextRankAfterChoice below walks the rest forward one
-- at a time as each card is answered.
function RankService.NextRankToAnnounce(data: Data, oldIndex: number, newIndex: number): number?
	if newIndex <= oldIndex then
		return nil
	end
	if data.Progress.PendingEpithet ~= nil then
		return nil
	end
	if data.Progress.Epithet == "" then
		return nil
	end
	return oldIndex + 1
end

-- Pure (H1 fix, REVIEW-M4-01): once `answeredRank`'s choice has just been
-- cleared (ChooseEpithet), decides whether Magoi has already reached the
-- NEXT rank up too - a single big grant across several thresholds walks
-- the player through one card per rank, in order, instead of announcing
-- only the final one.
function RankService.NextRankAfterChoice(data: Data, answeredRank: number): number?
	if data.Progress.PendingEpithet ~= nil then
		return nil
	end
	local currentIndex = (Ranks.rankFor(data.Progress.Magoi))
	if currentIndex > answeredRank then
		return answeredRank + 1
	end
	return nil
end

-- ==================== attributes ====================

local function refreshRankAttributes(player: Player, data: Data)
	local rankIndex = (Ranks.rankFor(data.Progress.Magoi))
	player:SetAttribute("Rank", Ranks.titleFor(data.Progress.Magoi, data.Character.Gender))
	player:SetAttribute("RankIndex", rankIndex)
	player:SetAttribute("Epithet", data.Progress.Epithet)
	player:SetAttribute("Alignment", Alignment.label(Alignment.alignmentFor(data.Progress.GoldRukh, data.Progress.BlackRukh)))
	player:SetAttribute("EpithetPending", data.Progress.PendingEpithet ~= nil)
end

-- ==================== the rank-up / origin moment ====================

-- Rolls three epithet choices for `rankIndex`, stores them as the pending
-- choice, refreshes attributes and fires RankUp. `origin` picks the White
-- Rukh Street Rat bank (DESIGN.md 3a: origin is always chosen before a life
-- is judged) instead of the player's actual current alignment. Callers
-- never pass more than one rank above whatever was last resolved -
-- NextRankToAnnounce/NextRankAfterChoice below are what decide `rankIndex`,
-- never AddMagoi's own newIndex directly (H1 fix, REVIEW-M4-01).
local function announceRankUp(player: Player, data: Data, rankIndex: number, origin: boolean)
	local gender = data.Character.Gender
	local rankTitle = Ranks.List[rankIndex].title

	local alignmentKey: RukhAlignment
	if origin then
		alignmentKey = "White"
	else
		alignmentKey = Alignment.alignmentFor(data.Progress.GoldRukh, data.Progress.BlackRukh)
	end

	local exclude: { string }? = if data.Progress.Epithet ~= "" then { data.Progress.Epithet } else nil
	local choices = Epithets.pick3(rankTitle, alignmentKey, gender, exclude)

	data.Progress.PendingEpithet = { rank = rankIndex, choices = choices }
	refreshRankAttributes(player, data)

	Remotes.Server.Fire("RankUp", player, {
		title = RankService.TitleForIndex(rankIndex, gender),
		rankIndex = rankIndex,
		alignment = Alignment.label(alignmentKey),
		choices = choices,
		origin = origin,
	})

	log:Info(
		string.format(
			"%s: RankUp %s (index %d, alignment %s, origin=%s)",
			player.Name,
			rankTitle,
			rankIndex,
			alignmentKey,
			tostring(origin)
		)
	)
end

-- Fires the origin choice (DESIGN.md 3a) the first time a life's character
-- creation is done with nothing chosen or pending yet.
local function checkOrigin(player: Player, data: Data)
	local gender = player:GetAttribute("Gender")
	if type(gender) ~= "number" then
		return
	end
	if not RankService.ShouldOfferOrigin(data, gender) then
		return
	end
	announceRankUp(player, data, 1, true)
end

-- ==================== public API (M5 missions call these) ====================

function RankService.AddMagoi(player: Player, amount: number, reason: string)
	local data = DataService.Get(player)
	if data == nil then
		log:Warn(string.format("AddMagoi(%s, %d, %s): no save loaded", player.Name, amount, reason))
		return
	end

	local oldMagoi = data.Progress.Magoi
	local oldIndex, newIndex = RankService.ApplyMagoi(data, amount)

	log:Info(string.format("%s Magoi %d -> %d (%+d, %s)", player.Name, oldMagoi, data.Progress.Magoi, amount, reason))
	LegacyBridge.Refresh(player, data)
	refreshRankAttributes(player, data)

	local announceIndex = RankService.NextRankToAnnounce(data, oldIndex, newIndex)
	if announceIndex then
		announceRankUp(player, data, announceIndex, false)
	end
end

function RankService.AddDeed(player: Player, kind: DeedKind, amount: number)
	local data = DataService.Get(player)
	if data == nil then
		log:Warn(string.format("AddDeed(%s, %s, %d): no save loaded", player.Name, kind, amount))
		return
	end

	-- Explicit annotations, not just decoration: an unannotated destructure
	-- of ApplyDeed's return hits the same luau-lsp widening as the `::` cast
	-- did in ApplyDeed itself (see its own comment) - annotating each local
	-- here avoids it too.
	local oldAlignment: RukhAlignment, newAlignment: RukhAlignment = RankService.ApplyDeed(data, kind, amount)

	log:Info(
		string.format("%s %s Rukh %+d (now %d/%d)", player.Name, kind, amount, data.Progress.GoldRukh, data.Progress.BlackRukh)
	)
	refreshRankAttributes(player, data)

	if newAlignment ~= oldAlignment and newAlignment ~= "White" then
		Remotes.Server.Fire("AlignmentChanged", player, { alignment = Alignment.label(newAlignment) })
		log:Info(string.format("%s: AlignmentChanged -> %s", player.Name, Alignment.label(newAlignment)))
	end
end

function RankService.GetRank(player: Player): (number, string)
	local data = DataService.Get(player)
	if data == nil then
		return 1, Ranks.List[1].title
	end
	local index = (Ranks.rankFor(data.Progress.Magoi))
	return index, RankService.TitleForIndex(index, data.Character.Gender)
end

function RankService.GetAlignment(player: Player): RukhAlignment
	local data = DataService.Get(player)
	if data == nil then
		return "White"
	end
	local alignment: RukhAlignment = Alignment.alignmentFor(data.Progress.GoldRukh, data.Progress.BlackRukh)
	return alignment
end

-- ==================== per-player registration ====================

-- One connection per session (not per life): CharacterService sets this
-- attribute to 0 at the start of every life (including a death's fresh
-- character) and to the real gender once CreateCharacter succeeds, so this
-- single signal both re-syncs a new life's rank/alignment and fires the
-- origin choice once creation completes.
local genderConnections: { [Player]: RBXScriptConnection } = {}

local function onGenderAttributeChanged(player: Player)
	local data = DataService.Get(player)
	if data == nil then
		return
	end

	local gender = player:GetAttribute("Gender")
	if gender == 0 then
		-- A fresh life (or a dev .fresh): DataService.NewLife/Wipe already
		-- reset Progress before the new character's Gender attribute is set
		-- back to 0, so just resync the display attributes to match -
		-- nothing to announce for a life that hasn't earned anything yet.
		refreshRankAttributes(player, data)
		return
	end

	checkOrigin(player, data)
end

local function registerPlayer(player: Player, data: Data)
	refreshRankAttributes(player, data)

	local pending = data.Progress.PendingEpithet
	if pending then
		-- A rank-up (or the origin choice) was still unanswered when this
		-- session ended; re-send the same stored choices so the client shows
		-- the card again instead of rolling a fresh (and possibly
		-- different) set.
		local origin = pending.rank == 1 and data.Progress.Epithet == ""
		local alignmentKey: RukhAlignment
		if origin then
			alignmentKey = "White"
		else
			alignmentKey = Alignment.alignmentFor(data.Progress.GoldRukh, data.Progress.BlackRukh)
		end

		Remotes.Server.Fire("RankUp", player, {
			title = RankService.TitleForIndex(pending.rank, data.Character.Gender),
			rankIndex = pending.rank,
			alignment = Alignment.label(alignmentKey),
			choices = pending.choices,
			origin = origin,
		})
	else
		checkOrigin(player, data)
	end

	genderConnections[player] = player:GetAttributeChangedSignal("Gender"):Connect(function()
		onGenderAttributeChanged(player)
	end)
end

local function clearPlayer(player: Player)
	local connection = genderConnections[player]
	if connection then
		connection:Disconnect()
		genderConnections[player] = nil
	end
end

-- ==================== dev commands ====================
-- Registered via DevService.Register, same as AgeService/HealthService's
-- own dev commands - and, for magoi/magoi+/rukh, re-registered under the
-- SAME names DevService itself already defined. Commands is just a plain
-- table keyed by name (DevService.Register is the public way any service
-- adds to it), so this overwrites those three with versions that route
-- through AddMagoi/AddDeed instead of writing Progress directly, without
-- DevService needing to require RankService back (Roblox errors on a
-- cyclic ModuleScript require, and RankService already requires DevService
-- for Register/ResolvePlayer).

-- Mirrors DevService's own splitTrailingPlayer (not exported): every value
-- before an optional trailing player name is a number, so a non-numeric
-- last token is unambiguously the player name.
local function splitTrailingPlayer(args: { string }): ({ string }, string?)
	if #args == 0 then
		return args, nil
	end
	local last = args[#args]
	if tonumber(last) == nil then
		local rest = table.clone(args)
		table.remove(rest, #rest)
		return rest, last
	end
	return args, nil
end

local function magoiCommand(mode: "set" | "add"): (Player, { string }) -> string
	return function(caller: Player, args: { string })
		local rest, playerArg = splitTrailingPlayer(args)
		local n = tonumber(rest[1])
		if n == nil then
			return string.format("usage: .magoi%s <n> [player]", if mode == "add" then "+" else "")
		end
		local target, err = DevService.ResolvePlayer(caller, playerArg)
		if target == nil then
			return err or "player not found"
		end
		local data = DataService.Get(target)
		if data == nil then
			return string.format("%s has no save loaded", target.Name)
		end

		local old = data.Progress.Magoi
		local amount = if mode == "add" then n else n - old
		RankService.AddMagoi(target, amount, "dev")

		return string.format("%s's Magoi: %d -> %d", target.Name, old, data.Progress.Magoi)
	end
end

local function rukhCommand(caller: Player, args: { string }): string
	local rest, playerArg = splitTrailingPlayer(args)
	local gold = tonumber(rest[1])
	local black = tonumber(rest[2])
	if gold == nil or black == nil then
		return "usage: .rukh <gold> <black> [player]"
	end
	local target, err = DevService.ResolvePlayer(caller, playerArg)
	if target == nil then
		return err or "player not found"
	end
	local data = DataService.Get(target)
	if data == nil then
		return string.format("%s has no save loaded", target.Name)
	end

	local oldGold, oldBlack = data.Progress.GoldRukh, data.Progress.BlackRukh
	RankService.AddDeed(target, "Gold", gold - oldGold)
	RankService.AddDeed(target, "Black", black - oldBlack)
	LegacyBridge.Refresh(target, data)

	return string.format("%s's Rukh: %d/%d -> %d/%d", target.Name, oldGold, oldBlack, data.Progress.GoldRukh, data.Progress.BlackRukh)
end

local function rankupCommand(caller: Player, args: { string }): string
	local target, err = DevService.ResolvePlayer(caller, args[1])
	if target == nil then
		return err or "player not found"
	end
	local data = DataService.Get(target)
	if data == nil then
		return string.format("%s has no save loaded", target.Name)
	end

	local oldMagoi = data.Progress.Magoi
	local nextThreshold = Ranks.nextThreshold(oldMagoi)
	if nextThreshold == nil then
		return string.format("%s is already at the top rank", target.Name)
	end

	RankService.AddMagoi(target, nextThreshold - oldMagoi, "dev rankup")
	return string.format("%s's Magoi: %d -> %d", target.Name, oldMagoi, data.Progress.Magoi)
end

-- Keeps the existing `.epithet <text> [player]` behaviour and adds
-- `.epithet clear [player]`, which clears both the epithet and any pending
-- choice (and, since that makes the life look freshly-created again,
-- re-checks the origin condition - handy for the playtester re-testing the
-- birth flow without a full `.fresh`).
local function epithetCommand(caller: Player, args: { string }): string
	if args[1] and args[1]:lower() == "clear" then
		local target, err = DevService.ResolvePlayer(caller, args[2])
		if target == nil then
			return err or "player not found"
		end
		local data = DataService.Get(target)
		if data == nil then
			return string.format("%s has no save loaded", target.Name)
		end

		data.Progress.Epithet = ""
		data.Progress.PendingEpithet = nil
		LegacyBridge.Refresh(target, data)
		refreshRankAttributes(target, data)
		checkOrigin(target, data)

		return string.format("%s's epithet cleared", target.Name)
	end

	local text = args[1]
	if text == nil then
		return "usage: .epithet clear|<text> [player] (quote multi-word text)"
	end
	local target, err = DevService.ResolvePlayer(caller, args[2])
	if target == nil then
		return err or "player not found"
	end
	local data = DataService.Get(target)
	if data == nil then
		return string.format("%s has no save loaded", target.Name)
	end

	local old = data.Progress.Epithet
	data.Progress.Epithet = text
	LegacyBridge.Refresh(target, data)
	refreshRankAttributes(target, data)

	return string.format("%s's epithet: %q -> %q", target.Name, old, text)
end

local function registerDevCommands()
	DevService.Register("magoi", "<n> [player] - set Magoi", magoiCommand("set"))
	DevService.Register("magoi+", "<n> [player] - add to Magoi", magoiCommand("add"))
	DevService.Register("rukh", "<gold> <black> [player] - set both Rukh tallies", rukhCommand)
	DevService.Register("rankup", "[player] - add exactly enough Magoi to reach the next rank", rankupCommand)
	DevService.Register("epithet", "clear|<text> [player] - clear the epithet/pending choice, or set epithet text", epithetCommand)
end

-- ==================== service ====================

function RankService:Init()
	registerDevCommands()

	Remotes.Server.On("ChooseEpithet", function(player: Player, index: number)
		local data = DataService.Get(player)
		if data == nil then
			return
		end

		-- Captured before ApplyChooseEpithet clears it - needed for the H1
		-- fix below (REVIEW-M4-01): walking forward one rank at a time once
		-- this choice is answered.
		local pendingBefore = data.Progress.PendingEpithet

		local ok, reason = RankService.ApplyChooseEpithet(data, index)
		if not ok then
			log:Warn(string.format("%s's ChooseEpithet(%s) rejected: %s", player.Name, tostring(index), reason or "invalid"))
			return
		end

		refreshRankAttributes(player, data)
		log:Info(string.format("%s chose the epithet %q", player.Name, data.Progress.Epithet))

		if pendingBefore then
			local announceIndex = RankService.NextRankAfterChoice(data, pendingBefore.rank)
			if announceIndex then
				announceRankUp(player, data, announceIndex, false)
			end
		end
	end)
end

function RankService:Start()
	DataService.Loaded:Connect(function(player: Player)
		local data = DataService.Get(player)
		if data then
			registerPlayer(player, data)
		end
	end)

	-- Catches a player whose DataService.Loaded already fired before this
	-- connection was made (the same race PlayerService/DataService's own
	-- catch-up loops guard against).
	for _, player in Players:GetPlayers() do
		if DataService.IsLoaded(player) then
			local data = DataService.Get(player)
			if data then
				registerPlayer(player, data)
			end
		end
	end

	Players.PlayerRemoving:Connect(clearPlayer)
end

return RankService
