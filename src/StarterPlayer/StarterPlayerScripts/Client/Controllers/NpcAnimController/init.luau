--!strict
-- Every NPC gets the player's full animation set (Bryan, 2026-09-30:
-- "give dummies the same animations, all of them - walk, run, fight").
-- NPCs have no Animate script and no client of their own, so this
-- controller animates them from the server's own state, on every client:
--
--   locomotion   idle / walk / run / jump / fall - Config.Character.
--                Animations, the SAME ids CharacterService gives a
--                player's Animate script - off Humanoid.Running (speed)
--                and StateChanged
--   stance/look  the combat stance idle and the dagger prop, through
--                CombatController.WireCharacterLook (identical code path)
--   combat       the combo animation with the same freeze-and-continue
--                chain as the player (SwingTrack): the server's
--                SwingContinue event is the NPC's "next click";
--                AttackCancelled stops it. Block pose off the Blocking
--                attribute, the run animation off Running, the four dashes
--                off the Dash event.
--
-- Animations played here don't replicate (no client owns an NPC), but
-- every client reads the same server state, so they all show the same
-- thing. NPCs are found by the "NPC" CollectionService tag NpcService puts
-- on every model it registers.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared:WaitForChild("Log"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Config = require(Shared:WaitForChild("Config"))

local CombatController = require(script.Parent.CombatController)
local SwingTrack = require(script.Parent.CombatController.SwingTrack)

local log = Log.new("NpcAnimController")

local NPC_TAG = "NPC"
local LOCOMOTION = Config.Character.Animations
local MOVE_ANIMATIONS = Config.Combat.MoveAnimations
local COMBO_ANIMATIONS: { [string]: string } = Config.Combat.ComboAnimations
-- The default R6 Animate scales the walk cycle by speed / 16 (walk speed).
local WALK_ANIM_REFERENCE_SPEED = 16

local NpcAnimController = {}

type Rig = {
	character: Model,
	idle: AnimationTrack,
	walk: AnimationTrack,
	run: AnimationTrack,
	jump: AnimationTrack,
	fall: AnimationTrack,
	block: AnimationTrack,
	dashForward: AnimationTrack,
	dashLeft: AnimationTrack,
	dashBack: AnimationTrack,
	dashRight: AnimationTrack,
	swing: { [string]: AnimationTrack },
	currentSwing: SwingTrack.Swing?,
	moveSpeed: number,
	airborne: boolean,
	connections: { RBXScriptConnection },
}

local rigs: { [Model]: Rig } = {}

local function loadTrack(animator: Animator, id: string, priority: Enum.AnimationPriority, looped: boolean?): AnimationTrack
	local animation = Instance.new("Animation")
	animation.AnimationId = id
	local track = animator:LoadAnimation(animation)
	track.Priority = priority
	if looped ~= nil then
		track.Looped = looped
	end
	return track
end

-- ==================== locomotion ====================

-- Walk and run sit at Action priority so they win over the stance idle
-- (Movement, CombatController's) while the NPC moves; the plain idle sits
-- at Core so the stance idle wins over IT while the NPC stands in combat.
-- Combat tracks (Action2+) override all of these, same as on a player.
local function updateLocomotion(rig: Rig)
	local moving = rig.moveSpeed > 0.1 and not rig.airborne
	local running = moving and rig.character:GetAttribute("Running") == true

	if running then
		if not rig.run.IsPlaying then
			rig.run:Play(0.1)
		end
	else
		rig.run:Stop(0.1)
	end

	if moving and not running then
		if not rig.walk.IsPlaying then
			rig.walk:Play(0.1)
		end
		rig.walk:AdjustSpeed(math.clamp(rig.moveSpeed / WALK_ANIM_REFERENCE_SPEED, 0.5, 2))
	else
		rig.walk:Stop(0.1)
	end

	if not moving and not rig.airborne then
		if not rig.idle.IsPlaying then
			rig.idle:Play(0.2)
		end
	else
		rig.idle:Stop(0.2)
	end
end

local function onStateChanged(rig: Rig, new: Enum.HumanoidStateType)
	if new == Enum.HumanoidStateType.Jumping then
		rig.airborne = true
		rig.fall:Stop(0.1)
		rig.jump:Play(0.1)
	elseif new == Enum.HumanoidStateType.Freefall then
		rig.airborne = true
		if not rig.fall.IsPlaying then
			rig.fall:Play(0.2)
		end
	elseif new == Enum.HumanoidStateType.Landed or new == Enum.HumanoidStateType.Running or new == Enum.HumanoidStateType.RunningNoPhysics then
		rig.airborne = false
		rig.jump:Stop(0.1)
		rig.fall:Stop(0.1)
	end
	updateLocomotion(rig)
end

-- ==================== combat ====================

local function updateBlockPose(rig: Rig)
	if rig.character:GetAttribute("Blocking") == true then
		if not rig.block.IsPlaying then
			rig.block:Play()
		end
	else
		rig.block:Stop()
	end
end

local function stopSwing(rig: Rig, fadeTime: number?)
	local swing = rig.currentSwing
	if swing then
		rig.currentSwing = nil
		swing.stop(fadeTime)
	end
end

local function onSwing(rig: Rig, data: any)
	stopSwing(rig, nil)
	local styleName = typeof(data.style) == "string" and data.style or "Fist"
	local hitCount = if typeof(data.hitCount) == "number" then data.hitCount else 1
	local track = rig.swing[styleName] or rig.swing.Fist
	if not track then
		return
	end
	local swing: SwingTrack.Swing
	swing = SwingTrack.new({
		character = rig.character,
		track = track,
		styleName = styleName,
		hitCount = hitCount,
		log = log,
		-- The player's own markers already fill Output; an NPC's would only
		-- double it. Flip this to Config.Combat.LogMarkers to read them.
		logMarkers = false,
		onStopped = function()
			if rig.currentSwing == swing then
				rig.currentSwing = nil
			end
		end,
	})
	rig.currentSwing = swing
end

local function pickDashTrack(rig: Rig, x: number, z: number): AnimationTrack
	if math.abs(z) >= math.abs(x) then
		return if z <= 0 then rig.dashForward else rig.dashBack
	end
	return if x >= 0 then rig.dashRight else rig.dashLeft
end

local function onCombatEvent(kind: any, data: any)
	if typeof(kind) ~= "string" or typeof(data) ~= "table" then
		return
	end
	local character = data.character
	if typeof(character) ~= "Instance" then
		return
	end
	local rig = rigs[character :: any]
	if not rig then
		return
	end

	if kind == "Swing" then
		onSwing(rig, data)
	elseif kind == "SwingContinue" then
		local swing = rig.currentSwing
		if swing then
			swing.continue()
		end
	elseif kind == "AttackCancelled" or kind == "AttackEnded" then
		stopSwing(rig, 0.1)
	elseif kind == "Dash" then
		local x = if typeof(data.x) == "number" then data.x else 0
		local z = if typeof(data.z) == "number" then data.z else 0
		pickDashTrack(rig, x, z):Play()
	end
end

-- ==================== rig lifecycle ====================

local function teardown(character: Model)
	local rig = rigs[character]
	if not rig then
		return
	end
	rigs[character] = nil
	stopSwing(rig, nil)
	for _, conn in rig.connections do
		conn:Disconnect()
	end
	table.clear(rig.connections)
	for _, track in { rig.idle, rig.walk, rig.run, rig.jump, rig.fall, rig.block } do
		track:Stop()
	end
end

local function setup(character: Model)
	if rigs[character] then
		return
	end
	local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
	local animator = humanoid and humanoid:WaitForChild("Animator", 5) :: Animator?
	if not humanoid or not animator or rigs[character] or character.Parent == nil then
		if not animator then
			log:Warn("no Animator on " .. character.Name .. "; NPC animations disabled")
		end
		return
	end

	CombatController.WireCharacterLook(character)

	local swing: { [string]: AnimationTrack } = {}
	for styleName, id in COMBO_ANIMATIONS do
		if id ~= "" then
			swing[styleName] = loadTrack(animator, id, Enum.AnimationPriority.Action2)
		end
	end

	local rig: Rig = {
		character = character,
		idle = loadTrack(animator, LOCOMOTION.Idle, Enum.AnimationPriority.Core, true),
		walk = loadTrack(animator, LOCOMOTION.Walk, Enum.AnimationPriority.Action, true),
		run = loadTrack(animator, LOCOMOTION.Run, Enum.AnimationPriority.Action, true),
		jump = loadTrack(animator, LOCOMOTION.Jump, Enum.AnimationPriority.Action, false),
		fall = loadTrack(animator, LOCOMOTION.Fall, Enum.AnimationPriority.Action, true),
		block = loadTrack(animator, MOVE_ANIMATIONS.Block, Enum.AnimationPriority.Action3),
		dashForward = loadTrack(animator, MOVE_ANIMATIONS.DashForward, Enum.AnimationPriority.Action3),
		dashLeft = loadTrack(animator, MOVE_ANIMATIONS.DashLeft, Enum.AnimationPriority.Action3),
		dashBack = loadTrack(animator, MOVE_ANIMATIONS.DashBack, Enum.AnimationPriority.Action3),
		dashRight = loadTrack(animator, MOVE_ANIMATIONS.DashRight, Enum.AnimationPriority.Action3),
		swing = swing,
		currentSwing = nil,
		moveSpeed = 0,
		airborne = false,
		connections = {},
	}
	rigs[character] = rig

	table.insert(
		rig.connections,
		humanoid.Running:Connect(function(speed: number)
			rig.moveSpeed = speed
			updateLocomotion(rig)
		end)
	)
	table.insert(
		rig.connections,
		humanoid.StateChanged:Connect(function(_old, new)
			onStateChanged(rig, new)
		end)
	)
	table.insert(
		rig.connections,
		character:GetAttributeChangedSignal("Running"):Connect(function()
			updateLocomotion(rig)
		end)
	)
	table.insert(
		rig.connections,
		character:GetAttributeChangedSignal("Blocking"):Connect(function()
			updateBlockPose(rig)
		end)
	)
	table.insert(
		rig.connections,
		character.AncestryChanged:Connect(function(_child, parent)
			if parent == nil then
				teardown(character)
			end
		end)
	)

	rig.moveSpeed = humanoid.MoveDirection.Magnitude * humanoid.WalkSpeed
	updateLocomotion(rig)
	updateBlockPose(rig)
end

local function onTagged(instance: Instance)
	if instance:IsA("Model") then
		task.spawn(setup, instance)
	end
end

function NpcAnimController:Init() end

function NpcAnimController:Start()
	Remotes.Client.On("CombatEvent", onCombatEvent)

	for _, instance in CollectionService:GetTagged(NPC_TAG) do
		onTagged(instance)
	end
	CollectionService:GetInstanceAddedSignal(NPC_TAG):Connect(onTagged)
	CollectionService:GetInstanceRemovedSignal(NPC_TAG):Connect(function(instance: Instance)
		if instance:IsA("Model") then
			teardown(instance)
		end
	end)

	log:Info("ready")
end

return NpcAnimController
