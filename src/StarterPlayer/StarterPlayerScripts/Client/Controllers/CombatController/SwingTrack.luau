--!strict
-- One playing combo animation on one character: the keyframe/marker logic
-- of the two-click chain (M3-FIX5), shared by CombatController (the local
-- player - it sends the hit reports and the clicks) and NpcAnimController
-- (every NPC - it mirrors the server's own chain off CombatEvents, so a
-- dummy throws, freezes and continues with the exact same animation a
-- player does; Bryan, 2026-09-30).
--
-- A chain is a run of SEGMENTS, one per hit. Segment 1 starts at Play();
-- once hit k's marker plays, the track keeps going until hit k+1's wind-up
-- marker, where it FREEZES (AdjustSpeed(0)) until `continue()` - the
-- player's next click, or the server's SwingContinue event for an NPC -
-- unfreezes it straight into that hit's own wind-up slowdown. The
-- configured names (Config.Combat.Markers[style]) can be animation EVENTS
-- (GetMarkerReachedSignal) or plain KEYFRAME names (KeyframeReached) -
-- Bryan's Fist animation uses keyframe names; both feed one dispatcher and
-- each name counts once.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
-- Typed `any`: read defensively via StyleHitData below rather than
-- assuming Combat.Styles' shape.
local CombatData: any = require(Shared:WaitForChild("Data"):WaitForChild("Combat"))

local SwingTrack = {}

local COMBO_SPEEDS: { [string]: number } = Config.Combat.ComboSpeed

export type Swing = {
	character: Model,
	track: AnimationTrack,
	styleName: string,
	hitCount: number,
	-- Config.Combat.ComboSpeed for this style: the track's speed outside a
	-- wind-up (restored after every hit marker and on every unfreeze).
	comboSpeed: number,
	-- The hit whose segment is live - 1 from Play(), k once continue()
	-- unfroze the track into hit k.
	segment: number,
	-- os.clock() when that segment started: the clock cancelUntil is
	-- measured against, and what the marker log prints next to each
	-- marker, since it's what the server checks hitWindow against.
	segmentStartedAt: number,
	-- os.clock() when the latest hit marker fired; nil before hit 1.
	lastHitAt: number?,
	-- True while the track is frozen at the next hit's wind-up marker.
	paused: boolean,
	stopped: boolean,
	-- Which hit indices have had their own wind-up marker reached, so the
	-- cancel rule can ask "has the NEXT unlanded hit's wind-up played yet".
	windupReached: { [number]: boolean },
	-- Which hit indices have had their hit marker play (a marker that
	-- reaches twice never counts twice).
	hit: { [number]: boolean },
	-- Unfreezes into hit `segment + 1`'s wind-up. A no-op once stopped or
	-- past the last hit.
	continue: () -> (),
	-- Idempotent: disconnects everything and stops the track (optional
	-- fade). Only the first call does anything.
	stop: (fadeTime: number?) -> (),
}

export type Params = {
	character: Model,
	track: AnimationTrack,
	styleName: string,
	hitCount: number,
	-- A Log instance; marker lines go through it when `logMarkers` is on.
	log: any,
	logMarkers: boolean,
	-- Hit `index`'s marker just played while that hit was live.
	onHit: ((index: number) -> ())?,
	-- The track just froze at hit `index`'s wind-up, waiting for continue().
	onFrozen: ((index: number) -> ())?,
	-- The swing ended for any reason (stop(), or the track reaching its end).
	onStopped: (() -> ())?,
}

-- ==================== per-hit style data (M3-FIX4, read defensively) ====================

-- Combat.Styles[styleName].chain[hitIndex] (kind/windupAt/cancelUntil/
-- windupSpeed/...), or nil if the style/index isn't in it. Never errors.
function SwingTrack.StyleHitData(styleName: string, hitIndex: number): any
	local styles = CombatData.Styles
	if typeof(styles) ~= "table" then
		return nil
	end
	local style = styles[styleName]
	if typeof(style) ~= "table" then
		return nil
	end
	local hits = style.chain
	if typeof(hits) ~= "table" then
		return nil
	end
	return hits[hitIndex]
end

-- The wind-up slowdown for a hit, as a MULTIPLIER on the style's
-- ComboSpeed (1 = no slowdown; Bryan 2026-09-30: "barely noticeable, but
-- sizable to punish"). Prefers the hit's own windupSpeed from Combat.luau;
-- Config.Combat.WindupSpeed is the fallback.
function SwingTrack.WindupSpeedFor(styleName: string, hitIndex: number): number
	local hitData = SwingTrack.StyleHitData(styleName, hitIndex)
	if hitData and typeof(hitData.windupSpeed) == "number" then
		return hitData.windupSpeed
	end
	return Config.Combat.WindupSpeed
end

-- ==================== the swing ====================

function SwingTrack.new(params: Params): Swing
	local track = params.track
	local styleName = params.styleName
	local hitCount = params.hitCount
	local character = params.character
	local log = params.log
	local markers = Config.Combat.Markers[styleName] or Config.Combat.Markers.Fist
	local comboSpeed = COMBO_SPEEDS[styleName] or 1
	local connections: { RBXScriptConnection } = {}

	local swing = {
		character = character,
		track = track,
		styleName = styleName,
		hitCount = hitCount,
		comboSpeed = comboSpeed,
		segment = 1,
		segmentStartedAt = os.clock(),
		lastHitAt = nil,
		paused = false,
		stopped = false,
		windupReached = {},
		hit = {},
	} :: Swing

	-- One line per marker/keyframe, with the track time AND the seconds
	-- since the live hit's own segment started - the number the server
	-- checks that hit's hitWindow/cancelUntil against, so Bryan can copy it
	-- straight into Combat.luau.
	local function logMarker(name: string)
		if params.logMarkers then
			log:Info(
				string.format(
					"marker: %s at %.3fs (hit %d, +%.3fs since its start)",
					name,
					track.TimePosition,
					swing.segment,
					os.clock() - swing.segmentStartedAt
				)
			)
		end
	end

	swing.stop = function(fadeTime: number?)
		if swing.stopped then
			return
		end
		swing.stopped = true
		for _, conn in connections do
			conn:Disconnect()
		end
		table.clear(connections)
		-- Restore full speed before stopping, so a wind-up slowdown (or a
		-- freeze) never bleeds into the fade-out or, since this track is
		-- reused next swing, sits at that speed while idle in between.
		track:AdjustSpeed(1)
		track:Stop(fadeTime)
		if params.onStopped then
			params.onStopped()
		end
	end

	swing.continue = function()
		local index = swing.segment + 1
		if swing.stopped or index > hitCount then
			return
		end
		swing.segment = index
		swing.segmentStartedAt = os.clock()
		swing.paused = false
		track:AdjustSpeed(comboSpeed * SwingTrack.WindupSpeedFor(styleName, index))
		if params.logMarkers then
			log:Info(string.format("continue: hit %d", index))
		end
	end

	local windupByName: { [string]: number } = {}
	for windupIndex, name in markers.Windup do
		windupByName[name] = windupIndex
	end
	local hitByName: { [string]: number } = {}
	for hitIndex, name in markers.Hit do
		hitByName[name] = hitIndex
	end

	local function onWindup(windupIndex: number, name: string)
		if swing.windupReached[windupIndex] then
			return
		end
		swing.windupReached[windupIndex] = true
		logMarker(name)
		-- The wind-up of the hit AFTER the one that just landed is the
		-- freeze point - the chain waits for continue() here.
		if windupIndex == swing.segment + 1 and windupIndex <= hitCount then
			if swing.hit[swing.segment] then
				swing.paused = true
				track:AdjustSpeed(0)
				if params.logMarkers then
					log:Info(string.format("frozen before hit %d", windupIndex))
				end
				if params.onFrozen then
					params.onFrozen(windupIndex)
				end
				return
			end
			-- Markers out of order (this wind-up came before the previous
			-- hit's own marker): don't freeze, or hit `segment` could never
			-- land. Keep playing and say so.
			log:Warn(string.format("%s reached before hit %d landed - check Config.Combat.Markers.%s", name, swing.segment, styleName))
		end
		-- Bryan (2026-09-28): slow the hit so it's readable -- and so the
		-- loop (cancel to bait, interrupt to punish) has a window to react
		-- in.
		track:AdjustSpeed(comboSpeed * SwingTrack.WindupSpeedFor(styleName, windupIndex))
		if character:GetAttribute("Stunned") == true or character:GetAttribute("Knocked") == true then
			-- The server reaches the same conclusion and sends its own
			-- AttackCancelled; stop is idempotent either way.
			swing.stop(0.1)
		end
	end

	local function onHit(hitIndex: number, name: string)
		if swing.hit[hitIndex] then
			return
		end
		logMarker(name)
		track:AdjustSpeed(comboSpeed)
		if hitIndex ~= swing.segment then
			-- A hit marker for a hit that hasn't been continued into yet (or
			-- one already past): marking it landed would wreck the chain
			-- state. Markers or their names are wrong.
			log:Warn(string.format("%s reached while hit %d is the live one - check Config.Combat.Markers.%s", name, swing.segment, styleName))
			return
		end
		swing.hit[hitIndex] = true
		swing.lastHitAt = os.clock()
		if params.onHit then
			params.onHit(hitIndex)
		end
	end

	local function onNamedEvent(name: string)
		if swing.stopped then
			return
		end
		local windupIndex = windupByName[name]
		if windupIndex then
			onWindup(windupIndex, name)
			return
		end
		local hitIndex = hitByName[name]
		if hitIndex then
			onHit(hitIndex, name)
			return
		end
		logMarker(name)
	end

	table.insert(connections, track.KeyframeReached:Connect(onNamedEvent))
	for name in windupByName do
		table.insert(
			connections,
			track:GetMarkerReachedSignal(name):Connect(function()
				onNamedEvent(name)
			end)
		)
	end
	for name in hitByName do
		table.insert(
			connections,
			track:GetMarkerReachedSignal(name):Connect(function()
				onNamedEvent(name)
			end)
		)
	end
	table.insert(
		connections,
		track.Stopped:Connect(function()
			swing.stop(nil)
		end)
	)

	track:Play(0.05, 1, comboSpeed)
	return swing
end

return SwingTrack
