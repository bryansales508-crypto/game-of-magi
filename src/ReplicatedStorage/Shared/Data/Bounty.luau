--!strict
-- Bounty hunting rules. Pure: the numbers live in Config.Bounty; this module turns them into answers (who is wanted, who may take a bounty, what a capture pays). No Player, no save, no remotes; BountyService is the only thing that touches them.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

export type Reward = {
	copper: number,
	magoi: number,
	gold: number, -- Gold Rukh deeds
}

local Bounty = {}

-- Shown for a wanted player outside every city region.
Bounty.UnknownCity = "Unknown"

-- Whether `amount` is on the board.
function Bounty.isWanted(amount: number): boolean
	return amount >= Config.Bounty.PostingThreshold
end

-- Whether a hunter of rank `rankIndex` (index into Data/Ranks) may take a bounty.
function Bounty.canTakeAtRank(rankIndex: number): boolean
	return rankIndex >= Config.Bounty.RankGateIndex
end

export type TrackingState = {
	lastKnown: Vector3,
	revealed: boolean,
	-- Seconds the hunter has stayed beyond RevealStuds since being revealed.
	beyondSeconds: number,
}

-- One tracking tick (Config.Bounty.Tracking.TickSeconds) for a hunter with the bounty Tool equipped. `targetPos` is nil while the target has no character. Returns a new state; never mutates `state`. Reach: a hunter near the last known spot refreshes it to the target's real position. Reveal: a hunter near the target sees them; staying away for LoseSeconds loses them, and the target's position at that moment becomes the last known spot.
function Bounty.NextTrackingState(hunterPos: Vector3, targetPos: Vector3?, state: TrackingState): TrackingState
	local rules = Config.Bounty.Tracking
	local lastKnown = state.lastKnown
	local revealed = state.revealed
	local beyondSeconds = state.beyondSeconds

	if targetPos and (hunterPos - lastKnown).Magnitude <= rules.ReachStuds then
		lastKnown = targetPos
	end

	if targetPos and (hunterPos - targetPos).Magnitude <= rules.RevealStuds then
		revealed = true
		beyondSeconds = 0
	elseif revealed then
		beyondSeconds += rules.TickSeconds
		if beyondSeconds >= rules.LoseSeconds then
			revealed = false
			beyondSeconds = 0
			lastKnown = targetPos or lastKnown
		end
	else
		beyondSeconds = 0
	end

	return { lastKnown = lastKnown, revealed = revealed, beyondSeconds = beyondSeconds }
end

-- What imprisoning a player with bounty `amount` pays the hunter. A bounty below the threshold pays nothing (the jail refuses it anyway).
function Bounty.rewardFor(amount: number): Reward
	if not Bounty.isWanted(amount) then
		return { copper = 0, magoi = 0, gold = 0 }
	end
	local rules = Config.Bounty.Reward
	local copper = math.floor(amount)
	local magoi = math.min(rules.MagoiCap, rules.MagoiBase + math.floor(amount / rules.MagoiDivisor))
	return { copper = copper, magoi = magoi, gold = rules.GoldRukhDeeds }
end

table.freeze(Bounty)

return Bounty
