--!strict
-- One playing combo animation on one character: the keyframe/marker logic
-- of the one-click-per-hit chain (M3-FIX5), shared by CombatController (the
-- local player - it sends the hit reports and the clicks) and
-- NpcAnimController (every NPC - it mirrors the server's own chain off
-- CombatEvents, so a dummy throws, freezes and continues with the exact
-- same animation a player does; Bryan, 2026-09-30).
--
-- M3-FIX6 (Bryan, 2026-10-01): "wind-up -> punch (pause) -> wind-up ->
-- punch (pause) -> ..." The track plays LOOPED and FREEZES ON THE PUNCH:
-- the moment a hit's marker plays, the track stops dead (AdjustSpeed(0))
-- in the impact pose and waits for `continue()` - the player's next click,
-- or the server's SwingContinue event for an NPC. continue() resumes it
-- into the follow-through and the next hit's wind-up, all at the style's
-- plain ComboSpeed (M3-FIX7: no wind-up slowdown; every hit is a Light),
-- until that punch, where it freezes again. After the chain's LAST hit the track wraps back to its
-- start, so hit 1 follows hit 2 follows hit 1 for as long as the clicks
-- keep coming; a chain only ends when a click doesn't come in time (the
-- server's "dropped" AttackCancelled fades the frozen pose out), or on a
-- cancel/interrupt/AttackEnded.
--
-- A chain is a run of SEGMENTS, one per hit thrown: segment 1 starts at
-- Play(), segment n at the (n-1)th continue(). `liveHit` is the chain
-- index the live segment throws (1..hitCount, wrapping). The configured
-- names (Config.Combat.Markers[style]) can be animation EVENTS
-- (GetMarkerReachedSignal) or plain KEYFRAME names (KeyframeReached) -
-- Bryan's Fist animation uses keyframe names; both feed one dispatcher and
-- each counts once per segment.
--
-- M7-02 (BUG-34, timer fallback): a style whose animation has no hit
-- keyframe/marker (the old Royal Dagger swing) would never report a hit, so
-- every segment also arms a timer for its live hit. If that hit's marker
-- hasn't played by the midpoint of its hitWindow (plus a FALLBACK_GRACE so a
-- marker authored exactly at the midpoint, as Fist's are, always wins the
-- tie), the timer calls the same onHit path with the name "<timer>": the
-- track freezes and AttackHit is reported inside the window. The timer is
-- cancelled by the marker, continue(), stop() and teardown, so a stopped
-- swing never reports. A missing wind-up marker never blocks it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
-- Typed `any`: read defensively via StyleHitData below rather than
-- assuming Combat.Styles' shape.
local CombatData: any = require(Shared:WaitForChild("Data"):WaitForChild("Combat"))

local SwingTrack = {}

local COMBO_SPEEDS: { [string]: number } = Config.Combat.ComboSpeed

-- Real seconds added to the hitWindow midpoint before the fallback timer
-- fires (never past the window's max), so a real marker at the midpoint
-- always arrives first.
local FALLBACK_GRACE = 0.1

export type Swing = {
	character: Model,
	track: AnimationTrack,
	styleName: string,
	hitCount: number,
	-- Config.Combat.ComboSpeed for this style: the track's one speed
	-- (restored after every unfreeze).
	comboSpeed: number,
	-- How many hits have been thrown (started) so far: 1 from Play(), +1
	-- per continue(). Only ever grows.
	segment: number,
	-- The chain index (1..hitCount) of the hit the live segment throws;
	-- wraps back to 1 after the chain's last hit.
	liveHit: number,
	-- os.clock() when the live segment started: the clock windupAt /
	-- cancelUntil / hitWindow are measured against (what the server checks),
	-- and what the marker log prints next to each marker.
	segmentStartedAt: number,
	-- os.clock() when the latest hit marker fired; nil before hit 1.
	lastHitAt: number?,
	-- True once the live hit's wind-up marker has played.
	windupSeen: boolean,
	-- True once the live hit's marker has played: the track is frozen in
	-- the punch pose, waiting for continue().
	landed: boolean,
	-- Same as `landed` (kept as the plain English name callers read).
	paused: boolean,
	stopped: boolean,
	-- Unfreezes into the next hit's segment. A no-op unless frozen.
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
	-- Hit `index`'s marker just played while that hit was live; the track
	-- is now frozen on it, waiting for continue().
	onHit: ((index: number) -> ())?,
	-- The swing ended for any reason (stop(), or the track reaching its end).
	onStopped: (() -> ())?,
}

-- ==================== per-hit style data (M3-FIX4, read defensively) ====================

-- Combat.Styles[styleName].chain[hitIndex] (windupAt/cancelUntil/
-- hitWindow/...), or nil if the style/index isn't in it. Never errors.
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

-- Combat.Styles[styleName].loopOffset: the seconds the last hit's
-- follow-through takes before the track wraps into hit 1 again (added to
-- hit 1's timings on every pass after the first). 0 if unknown.
function SwingTrack.LoopOffsetFor(styleName: string): number
	local styles = CombatData.Styles
	local style = if typeof(styles) == "table" then styles[styleName] else nil
	if typeof(style) == "table" and typeof(style.loopOffset) == "number" then
		return style.loopOffset
	end
	return 0
end

-- ==================== the swing ====================

function SwingTrack.new(params: Params): Swing
	local track = params.track
	local styleName = params.styleName
	local hitCount = math.max(1, params.hitCount)
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
		liveHit = 1,
		segmentStartedAt = os.clock(),
		lastHitAt = nil,
		windupSeen = false,
		landed = false,
		paused = false,
		stopped = false,
	} :: Swing

	-- One line per marker/keyframe, with the track time AND the seconds
	-- since the live hit's own segment started - the number the server
	-- checks that hit's hitWindow/cancelUntil against, so Bryan can copy it
	-- straight into Combat.luau.
	local function logMarker(name: string)
		if params.logMarkers then
			log:Info(
				string.format(
					"marker: %s at %.3fs (hit %d, segment %d, +%.3fs since its start)",
					name,
					track.TimePosition,
					swing.liveHit,
					swing.segment,
					os.clock() - swing.segmentStartedAt
				)
			)
		end
	end

	local onHit: (hitIndex: number, name: string) -> ()
	local fallbackTimer: thread? = nil

	local function cancelFallback()
		if fallbackTimer then
			task.cancel(fallbackTimer)
			fallbackTimer = nil
		end
	end

	-- Arms the timer for the live segment's hit (see the header comment).
	local function armFallback()
		cancelFallback()
		local hitData = SwingTrack.StyleHitData(styleName, swing.liveHit)
		local window = if hitData then hitData.hitWindow else nil
		if typeof(window) ~= "table" or typeof(window.min) ~= "number" or typeof(window.max) ~= "number" then
			return
		end
		local delaySeconds = window.min + (window.max - window.min) / 2 + FALLBACK_GRACE
		delaySeconds = math.min(delaySeconds, window.max)
		-- Same pass rule as the server: hit 1 after the first pass starts
		-- with the last hit's follow-through.
		if swing.liveHit == 1 and swing.segment > 1 then
			delaySeconds += SwingTrack.LoopOffsetFor(styleName)
		end
		local armedSegment = swing.segment
		fallbackTimer = task.delay(delaySeconds, function()
			fallbackTimer = nil
			if swing.stopped or swing.landed or swing.segment ~= armedSegment then
				return
			end
			if params.logMarkers then
				log:Info(string.format("fallback: hit %d at +%.3fs (no marker)", swing.liveHit, os.clock() - swing.segmentStartedAt))
			end
			onHit(swing.liveHit, "<timer>")
		end)
	end

	swing.stop = function(fadeTime: number?)
		if swing.stopped then
			return
		end
		swing.stopped = true
		cancelFallback()
		for _, conn in connections do
			conn:Disconnect()
		end
		table.clear(connections)
		-- Restore full speed before stopping, so a freeze never bleeds into
		-- the fade-out or, since this track is reused next swing, sits at
		-- speed 0 while idle in between.
		track:AdjustSpeed(1)
		track:Stop(fadeTime)
		if params.onStopped then
			params.onStopped()
		end
	end

	swing.continue = function()
		if swing.stopped or not swing.landed then
			return
		end
		swing.segment += 1
		swing.liveHit = swing.liveHit % hitCount + 1
		swing.segmentStartedAt = os.clock()
		swing.landed = false
		swing.paused = false
		swing.windupSeen = false
		-- Follow-through and the next wind-up at the style's ComboSpeed.
		track:AdjustSpeed(comboSpeed)
		armFallback()
		if params.logMarkers then
			log:Info(string.format("continue: hit %d (segment %d)", swing.liveHit, swing.segment))
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
		logMarker(name)
		if swing.landed or swing.windupSeen then
			-- Frozen on a punch, or this segment's wind-up already played:
			-- nothing to do (a wind-up for a later hit can't legitimately
			-- arrive while the track is frozen).
			return
		end
		if windupIndex ~= swing.liveHit then
			log:Warn(string.format("%s reached while hit %d is the live one - check Config.Combat.Markers.%s", name, swing.liveHit, styleName))
			return
		end
		swing.windupSeen = true
		if character:GetAttribute("Stunned") == true or character:GetAttribute("Knocked") == true then
			-- The server reaches the same conclusion and sends its own
			-- AttackCancelled; stop is idempotent either way.
			swing.stop(0.1)
		end
	end

	onHit = function(hitIndex: number, name: string)
		logMarker(name)
		if swing.landed then
			return
		end
		if hitIndex ~= swing.liveHit then
			-- A hit marker for a hit that hasn't been continued into yet (or
			-- one already past): marking it landed would wreck the chain
			-- state. Markers or their names are wrong.
			log:Warn(string.format("%s reached while hit %d is the live one - check Config.Combat.Markers.%s", name, swing.liveHit, styleName))
			return
		end
		-- The punch: freeze right here, in the impact pose, until the next
		-- click.
		cancelFallback()
		swing.landed = true
		swing.paused = true
		swing.lastHitAt = os.clock()
		track:AdjustSpeed(0)
		if params.logMarkers then
			log:Info(string.format("frozen on hit %d, waiting for the next click", hitIndex))
		end
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

	-- Looped so the chain can run "1, 2, 1, 2, ..." off one animation; the
	-- asset itself isn't authored as a loop, so set it here (every time -
	-- a track's Looped is its own property, but it costs nothing to be
	-- sure).
	track.Looped = true
	track:Play(0.05, 1, comboSpeed)
	armFallback()
	return swing
end

return SwingTrack
