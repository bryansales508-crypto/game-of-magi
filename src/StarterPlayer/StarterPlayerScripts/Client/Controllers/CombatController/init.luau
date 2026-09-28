--!strict
-- Input -> combat intentions, and the swing/dash/run animations that play
-- in lockstep with the server's own timing. See docs/SYSTEMS.md #8-9,
-- docs/AUDIT.md H6/H10/L11, docs/TRIAGE.md #11, docs/M3-PLAN.md M3-05,
-- docs/TINKER.md "Combat" (M3-FIX3, Bryan 2026-09-28).
--
-- The client never decides a hit or a cooldown: it only sends
-- AttackStart / AttackHit / AttackCancel / Block / Dash / Run intentions,
-- and only plays an animation once the server's own CombatEvent or
-- attribute confirms it (H6 -- the old script played the swing on click
-- and let clicks stack Hit-marker listeners).
--
-- M3-FIX3: one click plays ONE fist animation containing several punches
-- (right then left today). The animation's own markers drive the report:
-- a "wind-up" marker per punch (checked for an interrupt, and the first
-- one gates the cancel window) and a "hit" marker per punch (reports
-- AttackHit(index) at that instant, so client and server timing agree).
-- The real marker names can't be read from the .rbxm, so they're
-- editable data: Shared/Config.luau's Config.Combat.Markers, with
-- Config.Combat.LogMarkers logging every keyframe/marker reached on the
-- fist track so Bryan can read the real names out of Output.
--
-- Animation ids kept from the old SCS/Scripts/PhysicalHandler.client.luau
-- (785 lines) so the feel is unchanged:
--   Fist swing          rbxassetid://125726557974534  (Action2, speed 1.6)
--   Royal Dagger swing  rbxassetid://115894342135428  (Action2, speed 0.25; kept for M5 weapon sets)
--   Block / parry pose  rbxassetid://15429144750      (Action3)
--   Run                 rbxassetid://15421855688      (Action2)
--   Dash forward (W)    rbxassetid://18100686685
--   Dash left    (A)    rbxassetid://18101513350
--   Dash back    (S)    rbxassetid://18101228314
--   Dash right   (D)    rbxassetid://18101385205
-- The diagonal dash animations were commented out in the old script and
-- never existed (AUDIT H10); cardinal-only is the approved feel for now.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared:WaitForChild("Log"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Config = require(Shared:WaitForChild("Config"))

local log = Log.new("CombatController")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera :: Camera
local defaultFieldOfView = camera.FieldOfView

local CombatController = {}

-- ==================== animation ids ====================

local ANIMATION_IDS = {
	Fist = "rbxassetid://125726557974534",
	Dagger = "rbxassetid://115894342135428",
	Block = "rbxassetid://15429144750",
	Run = "rbxassetid://15421855688",
	DashForward = "rbxassetid://18100686685",
	DashLeft = "rbxassetid://18101513350",
	DashBack = "rbxassetid://18101228314",
	DashRight = "rbxassetid://18101385205",
}

-- Old per-weapon animation playback speed (PhysicalHandler's `aniSpeed`).
local SWING_SPEEDS: { [string]: number } = {
	Fist = 1.6,
	Dagger = 0.25,
}

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

-- Forward-declared: referenced by the Humanoid.StateChanged connection
-- below (jump cancels a held block), defined in the Block section further
-- down. Connections close over the local itself, not its value at
-- connect-time, so this is safe.
local cancelBlock: () -> ()
local tryCancelAttack: () -> ()

-- ==================== swing state (M3-FIX3: animation-driven punches) ====================

type SwingState = {
	track: AnimationTrack,
	setName: string,
	punchCount: number,
	firstWindupReached: boolean,
	stopped: boolean,
	connections: { RBXScriptConnection },
	-- REVIEW-M3-FIX3-C: which hit indices have already fired AttackHit
	-- for this swing, so a marker that reaches twice (a re-entrant
	-- GetMarkerReachedSignal firing, a looped/seeked track, ...) never
	-- reports the same punch twice.
	hit: { [number]: boolean },
}

local currentSwing: SwingState? = nil

-- Idempotent: disconnects the marker connections and stops the track
-- (with an optional fade), whether called from a marker handler, the
-- track's own Stopped signal, AttackCancelled, or CharacterRemoving. Safe
-- to call more than once for the same swing (only the first call does
-- anything -- "both paths stop it once", point 2).
local function stopSwing(fadeTime: number?)
	local swing = currentSwing
	if not swing or swing.stopped then
		return
	end
	swing.stopped = true
	currentSwing = nil
	for _, conn in swing.connections do
		conn:Disconnect()
	end
	table.clear(swing.connections)
	-- Restore full speed before stopping, so a wind-up slowdown never
	-- bleeds into the fade-out or, since this track is reused next swing
	-- (only overridden by the explicit speed on the next Play() call),
	-- sits at WindupSpeed while idle in between.
	swing.track:AdjustSpeed(1)
	swing.track:Stop(fadeTime)
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

	return {
		swing = {
			Fist = loadTrack(animator, ANIMATION_IDS.Fist, Enum.AnimationPriority.Action2),
			Dagger = loadTrack(animator, ANIMATION_IDS.Dagger, Enum.AnimationPriority.Action2),
		},
		block = loadTrack(animator, ANIMATION_IDS.Block, Enum.AnimationPriority.Action3),
		run = loadTrack(animator, ANIMATION_IDS.Run, Enum.AnimationPriority.Action2),
		dashForward = loadTrack(animator, ANIMATION_IDS.DashForward, Enum.AnimationPriority.Action2),
		dashLeft = loadTrack(animator, ANIMATION_IDS.DashLeft, Enum.AnimationPriority.Action2),
		dashBack = loadTrack(animator, ANIMATION_IDS.DashBack, Enum.AnimationPriority.Action2),
		dashRight = loadTrack(animator, ANIMATION_IDS.DashRight, Enum.AnimationPriority.Action2),
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

-- ==================== Attack ====================

-- M1: fires AttackStart() only -- it never plays anything itself. The
-- swing (and its per-punch markers) only starts once the server's own
-- Swing event arrives, below.
local function tryAttackStart()
	local character = currentCharacter
	if not character then
		return
	end
	if
		character:GetAttribute("Stunned") == true
		or character:GetAttribute("Knocked") == true
		or character:GetAttribute("TrueStunned") == true
		or character:GetAttribute("Blocking") == true
		or character:GetAttribute("Attacking") == true
	then
		return
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

-- Right-click/jump ALSO tries to cancel an in-progress attack, but only
-- before its first wind-up marker (point 3); past that, the swing must
-- carry through, so this just does nothing. Never stops the track
-- locally -- that only ever happens once the server's own AttackCancelled
-- arrives, so client and server never disagree about whether the swing
-- is still live.
tryCancelAttack = function()
	local swing = currentSwing
	if not swing or swing.firstWindupReached then
		return
	end
	Remotes.Client.Fire("AttackCancel")
end

-- ==================== Dash ====================

-- Camera-relative WASD, decomposed onto the camera's own flattened
-- right/forward axes (not raw world XZ, so holding W dashes the way the
-- camera is looking, not a fixed world direction); falls back to the
-- humanoid's current MoveDirection, then to the character's facing, when
-- no directional key is held (Q + "last movement direction", point 1).
-- The server normalises the result (H10: no direction here is ever
-- required to already be unit length).
local function cameraRelativeDashAxes(): (number, number)
	local cf = camera.CFrame
	local forward = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	local right = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z)
	forward = if forward.Magnitude > 1e-4 then forward.Unit else Vector3.new(0, 0, -1)
	right = if right.Magnitude > 1e-4 then right.Unit else Vector3.new(1, 0, 0)

	local forwardAmount = (UserInputService:IsKeyDown(Enum.KeyCode.W) and 1 or 0) - (UserInputService:IsKeyDown(Enum.KeyCode.S) and 1 or 0)
	local rightAmount = (UserInputService:IsKeyDown(Enum.KeyCode.D) and 1 or 0) - (UserInputService:IsKeyDown(Enum.KeyCode.A) and 1 or 0)

	local direction = forward * forwardAmount + right * rightAmount
	if direction.Magnitude < 1e-4 then
		local humanoid = currentCharacter and currentCharacter:FindFirstChildOfClass("Humanoid")
		local moveDirection = if humanoid then humanoid.MoveDirection else Vector3.zero
		if moveDirection.Magnitude > 1e-4 then
			direction = moveDirection
		else
			local rootPart = currentCharacter and currentCharacter:FindFirstChild("HumanoidRootPart") :: BasePart?
			direction = if rootPart then rootPart.CFrame.LookVector else forward
		end
	end

	return direction.X, direction.Z
end

local function tryDash()
	local character = currentCharacter
	if not character then
		return
	end
	if character:GetAttribute("Knocked") == true or character:GetAttribute("TrueStunned") == true then
		return
	end

	local nextDashAt = character:GetAttribute("NextDashAt")
	if typeof(nextDashAt) == "number" and Workspace:GetServerTimeNow() < nextDashAt then
		return
	end

	local x, z = cameraRelativeDashAxes()
	Remotes.Client.Fire("Dash", x, z)
end

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

-- ==================== Swing (M3-FIX3: animation-driven punches) ====================

-- Starts the swing track and wires its markers: a configured wind-up name
-- per punch (interrupt check + the cancel-window flag) and a configured
-- hit name per punch (reports AttackHit(index)), plus KeyframeReached
-- purely for the log -- see Config.Combat's own comment on why both exist
-- (markers need the right name guessed already; named keyframes surface
-- themselves for free).
local function onLocalSwing(character: Model, tracks: Tracks, data: any)
	-- A fresh Swing always supersedes whatever was still running.
	stopSwing(nil)

	local setName = typeof(data.setName) == "string" and data.setName or "Fist"
	local punchCount = if typeof(data.punchCount) == "number" then data.punchCount else 1
	local track = tracks.swing[setName] or tracks.swing.Fist

	local swing: SwingState = {
		track = track,
		setName = setName,
		punchCount = punchCount,
		firstWindupReached = false,
		stopped = false,
		connections = {},
		hit = {},
	}
	currentSwing = swing

	local function addConn(conn: RBXScriptConnection)
		table.insert(swing.connections, conn)
	end

	if Config.Combat.LogMarkers then
		addConn(track.KeyframeReached:Connect(function(keyframeName: string)
			log:Info(string.format("marker: %s at %.3fs", keyframeName, track.TimePosition))
		end))
	end

	for windupIndex, name in Config.Combat.Markers.Windup do
		addConn(track:GetMarkerReachedSignal(name):Connect(function()
			if Config.Combat.LogMarkers then
				log:Info(string.format("marker: %s at %.3fs", name, track.TimePosition))
			end
			if windupIndex == 1 then
				swing.firstWindupReached = true
			end
			-- Bryan (2026-09-28): slow the punch so it's readable -- and
			-- so the loop below (cancel to bait, interrupt to punish)
			-- actually has a window to react in.
			track:AdjustSpeed(Config.Combat.WindupSpeed)
			if character:GetAttribute("Stunned") == true or character:GetAttribute("Knocked") == true then
				-- The server reaches the same conclusion and sends its own
				-- AttackCancelled; stopSwing is idempotent either way.
				stopSwing(0.1)
			end
		end))
	end

	for hitIndex, name in Config.Combat.Markers.Hit do
		addConn(track:GetMarkerReachedSignal(name):Connect(function()
			if Config.Combat.LogMarkers then
				log:Info(string.format("marker: %s at %.3fs", name, track.TimePosition))
			end
			track:AdjustSpeed(1)
			if swing.hit[hitIndex] then
				return
			end
			swing.hit[hitIndex] = true
			Remotes.Client.Fire("AttackHit", hitIndex)
		end))
	end

	addConn(track.Stopped:Connect(function()
		stopSwing(nil)
	end))

	track:Play(0.05, 1, SWING_SPEEDS[setName] or SWING_SPEEDS.Fist)
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
-- (only before firstWindupReached), and the server's own interrupt on a
-- landed Hit -- nothing here plays a role beyond sending the right
-- intention at the right moment.

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
			setBlockHeld(true)
		elseif inputState == Enum.UserInputState.End then
			setBlockHeld(false)
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

function CombatController:Init() end

function CombatController:Start()
	ContextActionService:BindAction(
		"CombatInput",
		handleInputAction,
		false,
		Enum.UserInputType.MouseButton1,
		Enum.UserInputType.MouseButton2,
		Enum.KeyCode.F,
		Enum.KeyCode.Q,
		Enum.KeyCode.W
	)

	Remotes.Client.On("CombatEvent", onCombatEvent)

	player.CharacterAdded:Connect(onCharacterAdded)
	player.CharacterRemoving:Connect(teardownCharacter)
	if player.Character then
		onCharacterAdded(player.Character)
	end

	log:Info("ready")
end

return CombatController
