--!strict
-- Jail rules. Pure: the numbers live in Config.Bounty.Jail; this module answers sentence questions. No Player, no save; JailService is the only thing that touches them.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local Jail = {}

-- Seconds a prisoner serves for a bounty: bounty * SecondsPerBountyPoint, clamped to MinSeconds..MaxSeconds.
function Jail.SentenceSeconds(bounty: number): number
	local rules = Config.Bounty.Jail
	return math.clamp(math.floor(bounty * rules.SecondsPerBountyPoint), rules.MinSeconds, rules.MaxSeconds)
end

-- A sentence length safe to store: non-finite becomes 0, otherwise clamped to 0..MaxSeconds. Guards dev input; a real sentence comes from SentenceSeconds.
function Jail.SafeSeconds(seconds: number): number
	if seconds ~= seconds or seconds == math.huge or seconds == -math.huge then
		return 0
	end
	return math.clamp(seconds, 0, Config.Bounty.Jail.MaxSeconds)
end

-- Whether a sentence ending at `jailUntil` (os.time(), 0 = free) is still running at `now`.
function Jail.IsServing(jailUntil: number, now: number): boolean
	return jailUntil > now
end

-- Whole seconds left on the sentence (0 when free or done).
function Jail.RemainingSeconds(jailUntil: number, now: number): number
	return math.max(0, jailUntil - now)
end

table.freeze(Jail)

return Jail
