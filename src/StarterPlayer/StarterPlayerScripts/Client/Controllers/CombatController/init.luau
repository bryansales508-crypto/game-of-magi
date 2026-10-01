--!strict
-- Input -> combat intentions, and the swing/dash/run animations that play
-- in lockstep with the server's own timing. See docs/SYSTEMS.md #8-9,
-- docs/AUDIT.md H6/H10/L11, docs/TRIAGE.md #11, docs/M3-PLAN.md M3-05,
-- docs/TINKER.md "Combat" (M3-FIX3/M3-FIX4, Bryan 2026-09-28).
--
-- The client never decides a hit or a cooldown: it only sends
-- AttackStart / AttackHit / AttackCancel / Block / Dash / Run intentions,
-- and only plays an animation once the server's own CombatEvent or
-- attribute confirms it (H6 -- the old script played the swing on click
-- and let clicks stack Hit-marker listeners).
--
-- M3-FIX3/M3-FIX4: one click plays ONE swing animation for the attacker's
-- fighting style (the WeaponSet attribute -- "Fist" or "Dagger" today),
-- containing a chain of several hits. The animation's own markers drive
-- the report: a "wind-up" marker per hit (checked for an interrupt, and
-- gates that hit's own cancel window) and a "hit" marker per hit (reports
-- AttackHit(index) at that instant, so client and server timing agree).
-- The real marker names can't be read from the .rbxm, so they're editable
-- data, per style: Shared/Config.luau's Config.Combat.Markers[styleName],
-- with Config.Combat.LogMarkers logging every keyframe/marker reached on
-- whichever style's track is playing so Bryan can read the real names out
-- of Output.
--
-- M3-FIX4 also adds: a Light/Heavy `kind` and a `windupSpeed` per hit,
-- read from Shared/Data/Combat.luau's Combat.Styles (server-owned data,
-- M3-FIX4-S, built in parallel -- read here defensively, since that table
-- doesn't exist on every branch yet; falls back to Config.Combat.WindupSpeed
-- and the old marker-gated cancel rule when it's missing); the LightStunned
-- and Recovering attributes gating input alongside Stunned/Knocked/
-- TrueStunned; and a purely cosmetic Royal Dagger prop shown on ANY
-- character (not just the local one) whose WeaponSet is "Dagger".
--
-- M3-FIX5 (Bryan, 2026-09-30): one click per hit. The combo is still ONE
-- animation per style (Config.Combat.ComboAnimations), but after hit k
-- lands the track freezes at hit k+1's wind-up marker (AdjustSpeed(0))
-- until the player clicks again; that click sends AttackContinue(k+1) and
-- unfreezes the track straight into the wind-up slowdown. A click that
-- lands early (during hit k's follow-through, or inside Chain.HitGap) is
-- remembered and fires as soon as it's allowed; no click within
-- Chain.ClickTimeout and the server drops the combo (AttackCancelled
-- {reason = "dropped"}), with a local backstop that fades the frozen pose
-- out even if that event never arrives. Right-click while frozen is a
-- cancel the server always honours.
--
-- Every animation id lives in Config.Combat (StanceAnimations,
-- ComboAnimations, ComboSpeed, MoveAnimations) - nothing is hardcoded here.
-- The diagonal dash animations were commented out in the old script and
-- never existed (AUDIT H10); cardinal-only is the approved feel for now.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared:WaitForChild("Log"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Config = require(Shared:WaitForChild("Config"))

-- M3-FIX5: the combo animation's keyframe/freeze/continue logic, shared
-- with NpcAnimController so a dummy's chain looks exactly like a player's.
local SwingTrack = require(script.SwingTrack)

local log = Log.new("CombatController")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera :: Camera
local defaultFieldOfView = camera.FieldOfView

local CombatController = {}

-- ==================== animation ids (Config.Combat) ====================

local MOVE_ANIMATIONS = Config.Combat.MoveAnimations
local COMBO_ANIMATIONS: { [string]: string } = Config.Combat.ComboAnimations

local DOUBLE_TAP_WINDOW = 0.5 -- old `dp`
local RUN_ZOOM_IN_SECONDS = 1 -- old WalkingTween

type Tracks = {
	swing: { [string]: AnimationTrack },
	block: AnimationTrack,
	run: AnimationTrack,
	dashForward: AnimationTrack,
	dashLeft: AnimationTrack,
	dashBack: AnimationTrack,
	dashRight: AnimationTrack,
}

-- ==================== per-character state ====================

local currentCharacter: Model? = nil
local currentTracks: Tracks? = nil
local characterConns: { RBXScriptConnection } = {}

local blockHeld = false
local wantRun = false
local runAnimPlaying = false
local runningTween: Tween? = nil
-- The "you don't know how to fight yet" message (Stance section, below);
-- declared here so teardownCharacter can clean it up on respawn without
-- forward-referencing a local declared later in the file.
local activeLockedMessageGui: ScreenGui? = nil
local lockedMessageGeneration = 0

-- Forward-declared: referenced by the Humanoid.StateChanged connection
-- below (jump cancels a held block), defined in the Block section further
-- down. Connections close over the local itself, not its value at
-- connect-time, so this is safe.
local cancelBlock: () -> ()
local tryCancelAttack: () -> ()
-- Forward-declared for the same reason: onCharacterAdded (below) wires
-- the local character's dagger visual, but the function itself lives
-- further down, next to its "other players" counterpart.
local wireDaggerVisual: (character: Instance) -> ()
local wireStanceAnimation: (character: Instance) -> ()
local stopStanceAnimation: (character: Instance) -> ()

-- ==================== swing state (M3-FIX3/M3-FIX5: animation-driven punches) ====================

-- The local character's live combo animation (SwingTrack owns the
-- keyframe/freeze/continue logic; this file adds the hit reports and the
-- clicks on top).
local currentSwing: SwingTrack.Swing? = nil
-- A click that arrived before the track froze or before Chain.HitGap was
-- over - fires the continue the moment both allow it. Reset per swing.
local continueQueued = false

-- M3-FIX5: the "next hit" click, defined in the Swing section below but
-- called from tryAttackStart (Attack section) above it.
local tryContinue: (swing: SwingTrack.Swing) -> ()

-- Idempotent: stops the live swing (with an optional fade), whether called
-- from AttackCancelled, a fresh Swing, or CharacterRemoving. The track's
-- own end reaches the same place through SwingTrack's onStopped.
local function stopSwing(fadeTime: number?)
	local swing = currentSwing
	if not swing then
		return
	end
	currentSwing = nil
	swing.stop(fadeTime)
end

local function loadTrack(animator: Animator, id: string, priority: Enum.AnimationPriority): AnimationTrack
	local animation = Instance.new("Animation")
	animation.AnimationId = id
	local track = animator:LoadAnimation(animation)
	track.Priority = priority
	return track
end

local function buildTracks(character: Model): Tracks?
	local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
	if not humanoid then
		log:Warn("no Humanoid on " .. character.Name .. "; combat animations disabled")
		return nil
	end
	local animator = humanoid:WaitForChild("Animator", 5) :: Animator?
	if not animator then
		log:Warn("no Animator on " .. character.Name .. "; combat animations disabled")
		return nil
	end

	local swing: { [string]: AnimationTrack } = {}
	for styleName, id in COMBO_ANIMATIONS do
		if id ~= "" then
			swing[styleName] = loadTrack(animator, id, Enum.AnimationPriority.Action2)
		end
	end

	return {
		swing = swing,
		block = loadTrack(animator, MOVE_ANIMATIONS.Block, Enum.AnimationPriority.Action3),
		run = loadTrack(animator, MOVE_ANIMATIONS.Run, Enum.AnimationPriority.Action2),
		dashForward = loadTrack(animator, MOVE_ANIMATIONS.DashForward, Enum.AnimationPriority.Action2),
		dashLeft = loadTrack(animator, MOVE_ANIMATIONS.DashLeft, Enum.AnimationPriority.Action2),
		dashBack = loadTrack(animator, MOVE_ANIMATIONS.DashBack, Enum.AnimationPriority.Action2),
		dashRight = loadTrack(animator, MOVE_ANIMATIONS.DashRight, Enum.AnimationPriority.Action2),
	}
end

-- ==================== block pose (driven by the `Blocking` attribute) ====================

local function updateBlockPose()
	local tracks = currentTracks
	local character = currentCharacter
	if not tracks or not character then
		return
	end
	if character:GetAttribute("Blocking") == true then
		if not tracks.block.IsPlaying then
			tracks.block:Play()
		end
	else
		tracks.block:Stop()
	end
end

-- ==================== run: camera zoom + leg animation (driven by the `Running` attribute) ====================

local function applyRunZoom(running: boolean)
	if runningTween then
		runningTween:Cancel()
	end
	local humanoid = currentCharacter and currentCharacter:FindFirstChildOfClass("Humanoid")
	local tween: Tween
	if running then
		local walkSpeed = if humanoid then humanoid.WalkSpeed else 16
		tween = TweenService:Create(camera, TweenInfo.new(2), { FieldOfView = defaultFieldOfView + walkSpeed })
	else
		tween = TweenService:Create(camera, TweenInfo.new(RUN_ZOOM_IN_SECONDS), { FieldOfView = defaultFieldOfView })
	end
	runningTween = tween
	tween:Play()
end

local function updateRunAnimation()
	local tracks = currentTracks
	local character = currentCharacter
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not tracks or not character or not humanoid then
		return
	end

	local shouldPlay = character:GetAttribute("Running") == true and humanoid.MoveDirection.Magnitude > 0
	if shouldPlay and not runAnimPlaying then
		tracks.run:Play()
		runAnimPlaying = true
	elseif not shouldPlay and runAnimPlaying then
		tracks.run:Stop()
		runAnimPlaying = false
	end
end

-- ==================== teardown / setup ====================

local function teardownCharacter()
	stopSwing(nil)
	if currentCharacter then
		stopStanceAnimation(currentCharacter)
	end
	if activeLockedMessageGui then
		activeLockedMessageGui:Destroy()
		activeLockedMessageGui = nil
	end

	for _, conn in characterConns do
		conn:Disconnect()
	end
	table.clear(characterConns)

	if runningTween then
		runningTween:Cancel()
		runningTween = nil
	end
	camera.FieldOfView = defaultFieldOfView

	currentCharacter = nil
	currentTracks = nil
	blockHeld = false
	wantRun = false
	runAnimPlaying = false
end

local function onCharacterAdded(character: Model)
	teardownCharacter()
	currentCharacter = character
	-- Independent of the swing tracks below (only needs "Right Arm", not
	-- the Animator), and equally relevant for the local character.
	wireDaggerVisual(character)
	wireStanceAnimation(character)

	task.spawn(function()
		local tracks = buildTracks(character)
		if currentCharacter ~= character then
			-- Respawned again while tracks were loading; this attempt is stale.
			return
		end
		currentTracks = tracks
		if not tracks then
			return
		end

		table.insert(
			characterConns,
			character:GetAttributeChangedSignal("Blocking"):Connect(updateBlockPose)
		)
		table.insert(
			characterConns,
			character:GetAttributeChangedSignal("Running"):Connect(function()
				applyRunZoom(character:GetAttribute("Running") == true)
				updateRunAnimation()
			end)
		)

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			table.insert(characterConns, humanoid:GetPropertyChangedSignal("MoveDirection"):Connect(updateRunAnimation))
			table.insert(
				characterConns,
				humanoid.StateChanged:Connect(function(_old, new)
					if new == Enum.HumanoidStateType.Jumping then
						tryCancelAttack()
						cancelBlock()
					end
				end)
			)
		end

		updateBlockPose()
		applyRunZoom(character:GetAttribute("Running") == true)
	end)
end

-- ==================== input gating (M3-FIX4: LightStunned/Recovering) ====================

-- Fully incapacitated: nothing (Attack/Block/Dash) is allowed. Stunned/
-- Knocked/TrueStunned "as today" (point 4) -- unchanged from M3-FIX3;
-- Recovering is new and blocks everything the same way.
local function isIncapacitated(character: Model): boolean
	return character:GetAttribute("Stunned") == true
		or character:GetAttribute("Knocked") == true
		or character:GetAttribute("TrueStunned") == true
		or character:GetAttribute("Recovering") == true
end

-- LightStunned still allows Attack/Dash (point 4); only Block is narrower.
-- M3B-03: Block also requires InCombat (point 1), same as attacking/
-- cancelling -- see the Stance section below.
local function canBlock(character: Model): boolean
	return not isIncapacitated(character)
		and character:GetAttribute("LightStunned") ~= true
		and character:GetAttribute("InCombat") == true
end

-- ==================== Stance (M3B: combat is entered with a key) ====================
-- The style is entirely server-derived from the equipped Tool (WeaponSet)
-- -- this client never sends or claims a style, only SetStance(bool).

local LOCKED_MESSAGE_TEXT = "You don't know how to fight yet."
local LOCKED_MESSAGE_COLOR = Color3.fromRGB(255, 224, 152)

-- Same look as RukhController's "Your heart gave out." (menu-style font),
-- centred low on the screen per point 2. Generation-guarded so a second
-- press while one is already showing restarts the clock cleanly instead
-- of an earlier delayed cleanup destroying the newer GUI out from under it.
local function showLockedMessage()
	lockedMessageGeneration += 1
	local myGeneration = lockedMessageGeneration

	if activeLockedMessageGui then
		activeLockedMessageGui:Destroy()
		activeLockedMessageGui = nil
	end

	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "StanceLockedGui"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 900

	local label = Instance.new("TextLabel")
	label.Name = "Message"
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.fromScale(0.5, 0.82)
	label.Size = UDim2.fromScale(0.6, 0.07)
	label.BackgroundTransparency = 1
	label.FontFace = Font.new(Font.fromEnum(Enum.Font.Merriweather).Family, Enum.FontWeight.Regular, Enum.FontStyle.Italic)
	label.TextColor3 = LOCKED_MESSAGE_COLOR
	label.TextScaled = true
	label.Text = LOCKED_MESSAGE_TEXT
	label.Parent = gui

	gui.Parent = playerGui
	activeLockedMessageGui = gui

	task.delay(Config.Combat.LockedMessageSeconds, function()
		if lockedMessageGeneration == myGeneration then
			gui:Destroy()
			activeLockedMessageGui = nil
		end
	end)
end

-- The C key (Config.Combat.StanceKey): toggles InCombat. Leaving is
-- always sent instantly; entering while locked shows the message instead
-- of sending anything (point 2 -- "no remote sent").
local function tryToggleStance()
	local character = currentCharacter
	if not character then
		return
	end
	local wantOn = character:GetAttribute("InCombat") ~= true
	if wantOn then
		-- "Entering requires: combat unlocked, alive, not knocked or in a
		-- scene" (M3B-PLAN.md section 1); the server is the real gate,
		-- this just avoids a doomed round-trip. "Leaving is instant" --
		-- no equivalent check when wantOn is false.
		if player:GetAttribute("CombatUnlocked") ~= true then
			showLockedMessage()
			return
		end
		if isIncapacitated(character) then
			return
		end
	end
	Remotes.Client.Fire("SetStance", wantOn)
end

-- A Tool the character has equipped with a non-empty string `Weapon`
-- attribute (the same attribute the server reads to derive WeaponSet).
local function findEquippedWeaponTool(character: Model): Tool?
	for _, child in character:GetChildren() do
		if child:IsA("Tool") then
			local weapon = child:GetAttribute("Weapon")
			if typeof(weapon) == "string" and weapon ~= "" then
				return child
			end
		end
	end
	return nil
end

-- ==================== Attack ====================

-- M1: fires AttackStart() only -- it never plays anything itself. The
-- swing (and its per-hit markers) only starts once the server's own
-- Swing event arrives, below.
--
-- Point 1's exception: outside the stance, a click normally does
-- nothing -- EXCEPT with a weapon Tool equipped, where the click both
-- enters the stance (SetStance(true)) AND becomes the first hit
-- (AttackStart), sent in that order. This never checks CombatUnlocked
-- itself (unlike the C key): the server drops both silently if locked,
-- same as any other rejected SetStance.
local function tryAttackStart()
	local character = currentCharacter
	if not character then
		return
	end
	if isIncapacitated(character) or character:GetAttribute("Blocking") == true then
		return
	end

	-- M3-FIX5: a click mid-combo is the "next hit" click, once the current
	-- hit has landed (before that it's nothing - mashing during a wind-up
	-- never buffers). tryContinue (Swing section) waits for the track to
	-- freeze and for Chain.HitGap before it actually sends anything.
	-- Once the LAST hit has been clicked into, the swing no longer eats
	-- clicks: the server clears Attacking the moment that hit lands, and a
	-- click after Chain.Recovery starts the next combo (whose Swing event
	-- stops this track's follow-through) exactly as before.
	local swing = currentSwing
	if swing and not swing.stopped and swing.segment < swing.hitCount then
		if swing.hit[swing.segment] then
			continueQueued = true
			tryContinue(swing)
		end
		return
	end
	if character:GetAttribute("Attacking") == true then
		return
	end

	if character:GetAttribute("InCombat") ~= true then
		if not findEquippedWeaponTool(character) then
			return
		end
		Remotes.Client.Fire("SetStance", true)
	end

	-- Always read fresh (no cached cooldown of our own): a cancelled
	-- attack costs no recovery, so the server sets NextAttackAt to "now"
	-- rather than a future time, and the very next click here already
	-- sees that -- nothing else to do for that case.
	local nextAttackAt = character:GetAttribute("NextAttackAt")
	if typeof(nextAttackAt) == "number" and Workspace:GetServerTimeNow() < nextAttackAt then
		return
	end

	Remotes.Client.Fire("AttackStart")
end

-- ==================== Block ====================

local function setBlockHeld(held: boolean)
	if blockHeld == held then
		return
	end
	blockHeld = held
	Remotes.Client.Fire("Block", held)
end

-- Right-click / jump also releases a held block early, same as letting
-- go of F (independent of tryCancelAttack below, which is what handles
-- the swing/cancel-highlight side of these same two inputs).
cancelBlock = function()
	if blockHeld then
		setBlockHeld(false)
	end
end

-- The index of the earliest hit in this swing that hasn't landed yet, or
-- nil if every hit already has (nothing left to cancel).
local function nextUnlandedHitIndex(swing: SwingTrack.Swing): number?
	for index = 1, swing.hitCount do
		if not swing.hit[index] then
			return index
		end
	end
	return nil
end

-- Right-click/jump ALSO tries to cancel an in-progress attack (point 3):
-- eligible while the NEXT unlanded hit hasn't passed its own cancel point
-- -- a Light before its own wind-up marker (the old M3-FIX3 rule, and the
-- fallback when a hit's `kind` isn't available yet from Combat.Styles); a
-- Heavy until `cancelUntil` seconds after the swing started, by this
-- client's own clock (the server enforces the real check). Never stops
-- the track locally -- that only ever happens once the server's own
-- AttackCancelled arrives, so client and server never disagree about
-- whether the swing is still live.
tryCancelAttack = function()
	local character = currentCharacter
	if not character or character:GetAttribute("InCombat") ~= true then
		return
	end
	local swing = currentSwing
	if not swing then
		return
	end
	local nextIndex = nextUnlandedHitIndex(swing)
	if not nextIndex then
		return
	end

	-- M3-FIX5: between hits (the current hit landed, the next click not
	-- sent yet - frozen or still in the follow-through) a cancel is always
	-- honoured: that pause is the decision point. Also forgets a queued
	-- click, so the cancel can't race its own continue.
	if swing.hit[swing.segment] and swing.segment < swing.hitCount then
		continueQueued = false
		Remotes.Client.Fire("AttackCancel")
		return
	end

	local hitData = SwingTrack.StyleHitData(swing.styleName, nextIndex)
	local kind = if hitData then hitData.kind else nil

	if kind == "Heavy" then
		local cancelUntil = if hitData and typeof(hitData.cancelUntil) == "number" then hitData.cancelUntil else nil
		if not cancelUntil or os.clock() - swing.segmentStartedAt > cancelUntil then
			return
		end
	elseif swing.windupReached[nextIndex] then
		return
	end

	Remotes.Client.Fire("AttackCancel")
end

-- ==================== Dash ====================

-- The dash direction in the CHARACTER'S OWN frame (x = right, z = back,
-- so (0, -1) is straight ahead), which is what MovementService.Dash
-- expects - it rotates (x, 0, z) by the HumanoidRootPart's CFrame.
-- (Bryan, 2026-09-30: dashes went the wrong way because this used to send
-- a world-space direction, which the server then rotated by the facing a
-- second time.)
--
-- WASD is read camera-relative (holding W dashes the way the camera
-- looks, as movement does), then converted into the character's frame;
-- with no key held it's the humanoid's current MoveDirection, and standing
-- still it's straight ahead, the way the character is facing (Q + "last
-- movement direction", point 1). The server normalises the result (H10).
local function characterRelativeDashAxes(): (number, number)
	local rootPart = currentCharacter and currentCharacter:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not rootPart then
		return 0, -1
	end

	local cf = camera.CFrame
	local forward = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	local right = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z)
	forward = if forward.Magnitude > 1e-4 then forward.Unit else Vector3.new(0, 0, -1)
	right = if right.Magnitude > 1e-4 then right.Unit else Vector3.new(1, 0, 0)

	local forwardAmount = (UserInputService:IsKeyDown(Enum.KeyCode.W) and 1 or 0) - (UserInputService:IsKeyDown(Enum.KeyCode.S) and 1 or 0)
	local rightAmount = (UserInputService:IsKeyDown(Enum.KeyCode.D) and 1 or 0) - (UserInputService:IsKeyDown(Enum.KeyCode.A) and 1 or 0)

	local worldDirection = forward * forwardAmount + right * rightAmount
	if worldDirection.Magnitude < 1e-4 then
		local humanoid = currentCharacter and currentCharacter:FindFirstChildOfClass("Humanoid")
		local moveDirection = if humanoid then humanoid.MoveDirection else Vector3.zero
		if moveDirection.Magnitude > 1e-4 then
			worldDirection = moveDirection
		else
			return 0, -1
		end
	end

	local localDirection = rootPart.CFrame:VectorToObjectSpace(worldDirection)
	return localDirection.X, localDirection.Z
end

local function tryDash()
	local character = currentCharacter
	if not character then
		return
	end
	-- "As today" for Knocked/TrueStunned (point 4: no plain Stunned check
	-- here, unchanged from before); Recovering is the new addition, and
	-- LightStunned deliberately does NOT block Dash.
	if
		character:GetAttribute("Knocked") == true
		or character:GetAttribute("TrueStunned") == true
		or character:GetAttribute("Recovering") == true
	then
		return
	end

	local nextDashAt = character:GetAttribute("NextDashAt")
	if typeof(nextDashAt) == "number" and Workspace:GetServerTimeNow() < nextDashAt then
		return
	end

	local x, z = characterRelativeDashAxes()
	Remotes.Client.Fire("Dash", x, z)
end

-- (x, z) are character-relative (the same numbers sent to the server and
-- echoed back in the Dash event), so z < 0 is forward and x > 0 is right.
local function pickDashTrack(x: number, z: number, tracks: Tracks): AnimationTrack
	if math.abs(z) >= math.abs(x) then
		return if z <= 0 then tracks.dashForward else tracks.dashBack
	end
	return if x >= 0 then tracks.dashRight else tracks.dashLeft
end

-- ==================== Run ====================

local lastWPressTime = 0

local function startRun()
	if wantRun then
		return
	end
	wantRun = true
	Remotes.Client.Fire("Run", true)
end

local function stopRun()
	if not wantRun then
		return
	end
	wantRun = false
	Remotes.Client.Fire("Run", false)
end

-- ==================== Swing (M3-FIX3/M3-FIX4/M3-FIX5: animation-driven hit chains) ====================
-- The keyframe/marker logic (wind-up slowdown, hit markers, the freeze at
-- the next hit's wind-up, continue) lives in SwingTrack, shared with
-- NpcAnimController. This section is only what's specific to the LOCAL
-- player: reporting each hit to the server, and turning clicks into
-- continues.

-- The click for hit `swing.segment + 1`: sends AttackContinue and unfreezes
-- the track straight into that hit's own wind-up slowdown (its wind-up
-- marker is where the track froze, so the wind-up starts here - windupAt
-- 0 in Combat.luau). Optimistic on purpose: waiting for a server round
-- trip would add latency to every hit after the first. If the server
-- disagrees (the chain already timed out, a status landed), its own
-- AttackCancelled arrives and stopSwing fades the track out as usual.
local function continueSwing(swing: SwingTrack.Swing)
	continueQueued = false
	Remotes.Client.Fire("AttackContinue", swing.segment + 1)
	swing.continue()
end

-- Fires a queued click once BOTH hold: the track is frozen at the next
-- hit's wind-up marker, and Chain.HitGap has passed since the last hit
-- landed. Re-checks itself when only the gap is still running; a click
-- that arrives before the freeze is picked up by onFrozen calling this
-- again.
tryContinue = function(swing: SwingTrack.Swing)
	if swing.stopped or not swing.paused or not continueQueued then
		return
	end
	local gapEndsAt = (swing.lastHitAt or 0) + Config.Combat.Chain.HitGap
	local wait = gapEndsAt - os.clock()
	if wait > 0 then
		task.delay(wait, function()
			tryContinue(swing)
		end)
		return
	end
	local character = currentCharacter
	if not character or isIncapacitated(character) then
		return
	end
	continueSwing(swing)
end

-- The track just froze at hit `index`'s wind-up, waiting for the click:
-- arm the local backstop (the server's own AttackCancelled "dropped"
-- normally gets here first; this only guarantees the frozen pose never
-- sticks if that event is lost) and fire any click that's already queued.
local function onFrozen(swing: SwingTrack.Swing, index: number)
	task.delay(Config.Combat.Chain.ClickTimeout + Config.Combat.HitTolerance, function()
		if currentSwing == swing and swing.paused and not swing.stopped then
			if Config.Combat.LogMarkers then
				log:Info(string.format("combo dropped locally: no click for hit %d", index))
			end
			stopSwing(0.1)
		end
	end)
	tryContinue(swing)
end

local function onLocalSwing(character: Model, tracks: Tracks, data: any)
	-- A fresh Swing always supersedes whatever was still running.
	stopSwing(nil)
	continueQueued = false

	-- A feint arrives as an ordinary Swing (the server starts it as a new
	-- attack, point 5) -- nothing special-cased here, it just plays this
	-- style's track from its first hit like any other swing.
	local styleName = typeof(data.style) == "string" and data.style or "Fist"
	local hitCount = if typeof(data.hitCount) == "number" then data.hitCount else 1
	local track = tracks.swing[styleName] or tracks.swing.Fist
	if not track then
		log:Warn("no combo animation for style " .. styleName .. " (Config.Combat.ComboAnimations)")
		return
	end

	local swing: SwingTrack.Swing
	swing = SwingTrack.new({
		character = character,
		track = track,
		styleName = styleName,
		hitCount = hitCount,
		log = log,
		logMarkers = Config.Combat.LogMarkers,
		onHit = function(index: number)
			Remotes.Client.Fire("AttackHit", index)
		end,
		onFrozen = function(index: number)
			onFrozen(swing, index)
		end,
		onStopped = function()
			if currentSwing == swing then
				currentSwing = nil
			end
		end,
	})
	currentSwing = swing
end

-- ==================== CombatEvent (server -> client) ====================

-- Only ever animates the LOCAL character: a swing/dash played on your own
-- Animator replicates to every other client on its own (Roblox networks
-- animations from whichever client owns the character), so there is
-- nothing for this controller to do about another character's Swing or
-- Dash -- that plays on their own client instead.
--
-- This is also why the wind-up slowdown (onLocalSwing's AdjustSpeed
-- calls, Bryan 2026-09-28) doesn't need its own "other characters" path:
-- it's a runtime change to the SAME track that's already replicating, so
-- everyone watching an attacker sees the same slowdown through that
-- existing replication, the same way they already see the swing itself.
-- Deliberately NOT loading and playing a second, independent copy of the
-- track for every observer here -- that would double up with the
-- replicated one and fight it (two tracks driving the same joints).
-- FLAG FOR PLAYTEST: confirm the slowdown is visible to other players;
-- if AdjustSpeed turns out not to replicate reliably, that's the fallback
-- to build instead.
local function onCombatEvent(kind: any, data: any)
	if typeof(kind) ~= "string" or typeof(data) ~= "table" then
		log:Warn("CombatEvent: unexpected payload")
		return
	end

	local character = currentCharacter
	local tracks = currentTracks
	if not character or not tracks or data.character ~= character then
		return
	end

	if kind == "Swing" then
		onLocalSwing(character, tracks, data)
	elseif kind == "AttackCancelled" then
		-- Both "cancelled" and "interrupted" stop the local track the same
		-- way; EffectsController handles the highlight/stagger visuals.
		stopSwing(0.1)
	elseif kind == "Dash" then
		local x = if typeof(data.x) == "number" then data.x else 0
		local z = if typeof(data.z) == "number" then data.z else 0
		pickDashTrack(x, z, tracks):Play()
	end
end

-- The intended read-and-react loop this all serves (Bryan, 2026-09-28):
-- you swing -> the enemy reads your wind-up and swings back to interrupt
-- you -> next time, you cancel before your first wind-up to bait their
-- interrupt-swing -> then swing for real and interrupt THEM mid wind-up.
-- Every step of that is just these pieces: tryAttackStart, tryCancelAttack
-- (only before the next unlanded hit's own cancel point), and the
-- server's own interrupt on a landed Hit -- nothing here plays a role
-- beyond sending the right intention at the right moment.

-- ==================== dagger visual (M3-FIX4: purely cosmetic weapon prop) ====================
-- Shows the Royal Dagger, welded into the right hand, on ANY character
-- (own and others -- point 6) whose WeaponSet attribute is "Dagger";
-- removed the moment it changes to anything else. Grip CFrame and the
-- Motor6D-to-"Right Arm" approach are the old RS/Modules/Combat/
-- WeaponHandler.luau's `rig`, kept verbatim (git show a70f9ae:
-- src/ReplicatedStorage/Modules/Combat/WeaponHandler.luau, the commit
-- before that file was deleted). The real, functional tool comes with
-- the M5 shop; this is only ever a look.

local DAGGER_TEMPLATE =
	ReplicatedFirst:WaitForChild("Tools"):WaitForChild("Weapons"):WaitForChild("BasicWeapons"):WaitForChild("Royal Dagger")
local DAGGER_GRIP_C0 = CFrame.new(0, -1.5, -0.8) * CFrame.Angles(math.rad(-45), 0, 0)

-- Weak keys: a character destroyed without ever clearing WeaponSet (e.g.
-- a hard respawn) just drops out of this table on its own; the cloned
-- tool goes with the character model regardless, since it's parented
-- inside it.
local daggerToolByCharacter = (setmetatable({}, { __mode = "k" }) :: any) :: { [Instance]: Instance }

local function removeDaggerVisual(character: Instance)
	local tool = daggerToolByCharacter[character]
	if tool then
		daggerToolByCharacter[character] = nil
		tool:Destroy()
	end
end

local function showDaggerVisual(character: Instance)
	if daggerToolByCharacter[character] then
		return
	end
	local arm = character:FindFirstChild("Right Arm")
	if not (arm and arm:IsA("BasePart")) then
		return
	end

	local tool = DAGGER_TEMPLATE:Clone()
	local handle = tool:FindFirstChild("Handle")
	if not (handle and handle:IsA("BasePart")) then
		log:Warn("Royal Dagger template has no Handle; skipping the visual")
		tool:Destroy()
		return
	end
	handle.Anchored = false
	handle.CanCollide = false

	local grip = Instance.new("Motor6D")
	grip.Name = "WeaponGrip"
	grip.Part0 = arm
	grip.Part1 = handle
	grip.C0 = DAGGER_GRIP_C0
	grip.Parent = arm

	tool.Parent = character
	daggerToolByCharacter[character] = tool
end

local function updateDaggerVisual(character: Instance)
	if character:GetAttribute("WeaponSet") == "Dagger" then
		showDaggerVisual(character)
	else
		removeDaggerVisual(character)
	end
end

-- Shared by the local character (onCharacterAdded) and every other
-- player's (Start's wireOtherPlayer, below) -- the visual is the same
-- either way, only WHICH characters get watched differs.
wireDaggerVisual = function(character: Instance)
	character:GetAttributeChangedSignal("WeaponSet"):Connect(function()
		updateDaggerVisual(character)
	end)
	updateDaggerVisual(character)
end

-- ==================== stance animation (M3B point 3) ====================
-- One looping idle per style (Config.Combat.StanceAnimations), played on
-- ANY character (own and others) while its InCombat attribute is true;
-- stopped on InCombat clearing, a style change, or CharacterRemoving.
-- Movement priority: high enough to override the default standing idle,
-- but below the Action2/3-priority swing/block/dash tracks (theirs and
-- EffectsController's stagger/stunned-pose logic both key off Action-and-
-- above, so this never gets mistaken for "a combat animation is playing").

local stanceTrackByCharacter = (setmetatable({}, { __mode = "k" }) :: any) :: { [Instance]: AnimationTrack }

stopStanceAnimation = function(character: Instance)
	local track = stanceTrackByCharacter[character]
	if track then
		stanceTrackByCharacter[character] = nil
		track:Stop()
	end
end

local function updateStanceAnimation(character: Instance)
	if character:GetAttribute("InCombat") ~= true then
		stopStanceAnimation(character)
		return
	end

	local weaponSet = character:GetAttribute("WeaponSet")
	local styleName = if typeof(weaponSet) == "string" then weaponSet else "Fist"
	local animationId = Config.Combat.StanceAnimations[styleName]
	if typeof(animationId) ~= "string" or animationId == "" then
		stopStanceAnimation(character)
		return
	end

	local existing = stanceTrackByCharacter[character]
	if existing and existing.IsPlaying and existing.Animation and existing.Animation.AnimationId == animationId then
		return -- already the right style's idle; never stack a second copy
	end
	stopStanceAnimation(character)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = animationId
	local track = animator:LoadAnimation(animation)
	track.Priority = Enum.AnimationPriority.Movement
	track.Looped = true
	track:Play()
	track:AdjustSpeed(Config.Combat.StanceSpeed)
	stanceTrackByCharacter[character] = track
end

wireStanceAnimation = function(character: Instance)
	character:GetAttributeChangedSignal("InCombat"):Connect(function()
		updateStanceAnimation(character)
	end)
	character:GetAttributeChangedSignal("WeaponSet"):Connect(function()
		updateStanceAnimation(character)
	end)
	updateStanceAnimation(character)
end

-- ==================== input wiring (bound once; nothing here depends on the character) ====================

local function handleInputAction(_actionName: string, inputState: Enum.UserInputState, inputObject: InputObject): Enum.ContextActionResult
	if UserInputService:GetFocusedTextBox() then
		return Enum.ContextActionResult.Pass
	end

	if inputObject.UserInputType == Enum.UserInputType.MouseButton1 then
		if inputState == Enum.UserInputState.Begin then
			tryAttackStart()
		end
	elseif inputObject.UserInputType == Enum.UserInputType.MouseButton2 then
		if inputState == Enum.UserInputState.Begin then
			tryCancelAttack()
			cancelBlock()
		end
	elseif inputObject.KeyCode == Enum.KeyCode.F then
		if inputState == Enum.UserInputState.Begin then
			if currentCharacter and canBlock(currentCharacter) then
				setBlockHeld(true)
			end
		elseif inputState == Enum.UserInputState.End then
			setBlockHeld(false)
		end
	elseif inputObject.KeyCode == Config.Combat.StanceKey then
		if inputState == Enum.UserInputState.Begin then
			tryToggleStance()
		end
	elseif inputObject.KeyCode == Enum.KeyCode.Q then
		if inputState == Enum.UserInputState.Begin then
			tryDash()
		end
	elseif inputObject.KeyCode == Enum.KeyCode.W then
		if inputState == Enum.UserInputState.Begin then
			local now = os.clock()
			if now - lastWPressTime <= DOUBLE_TAP_WINDOW then
				startRun()
			end
			lastWPressTime = now
		elseif inputState == Enum.UserInputState.End then
			stopRun()
		end
	end

	return Enum.ContextActionResult.Pass
end

-- The look every combatant shares, player or NPC: the dagger prop while
-- WeaponSet is "Dagger", and the stance idle while InCombat.
-- NpcAnimController calls this for every NPC so the code path is one.
function CombatController.WireCharacterLook(character: Instance)
	wireDaggerVisual(character)
	wireStanceAnimation(character)
end

function CombatController:Init() end

function CombatController:Start()
	ContextActionService:BindAction(
		"CombatInput",
		handleInputAction,
		false,
		Enum.UserInputType.MouseButton1,
		Enum.UserInputType.MouseButton2,
		Enum.KeyCode.F,
		Config.Combat.StanceKey,
		Enum.KeyCode.Q,
		Enum.KeyCode.W
	)

	Remotes.Client.On("CombatEvent", onCombatEvent)

	player.CharacterAdded:Connect(onCharacterAdded)
	player.CharacterRemoving:Connect(teardownCharacter)
	if player.Character then
		onCharacterAdded(player.Character)
	end

	-- The dagger visual and the stance animation are the only things in
	-- this controller that care about characters other than the local
	-- one (points 3 and 6).
	local function wireOtherPlayer(otherPlayer: Player)
		if otherPlayer == player then
			return
		end
		otherPlayer.CharacterAdded:Connect(CombatController.WireCharacterLook)
		if otherPlayer.Character then
			CombatController.WireCharacterLook(otherPlayer.Character)
		end
	end
	for _, otherPlayer in Players:GetPlayers() do
		wireOtherPlayer(otherPlayer)
	end
	Players.PlayerAdded:Connect(wireOtherPlayer)

	log:Info("ready")
end

return CombatController
