--!strict
-- Everything the player sees and hears in combat: hit/block/parry/
-- block-break sound and particle reactions, the miss sound when a swing
-- lands on nothing, the knockout blind screen and input freeze, and the
-- dash trail. Driven entirely by the server's CombatEvent broadcasts and
-- status attributes -- the server still decides every hit, cooldown and
-- stun; this file only reacts. See docs/SYSTEMS.md #9-10, docs/AUDIT.md
-- M18, docs/M3-PLAN.md M3-06. The input/animation half (swing, dash,
-- block pose, run camera zoom) is Client/Controllers/CombatController
-- (M3-05); this file never touches the run zoom or the block pose so the
-- two controllers don't fight over the same tween/track.
--
-- Every character (not just the local player) gets its Hit/Blocked/
-- Parried/BlockBroken/Dash/AttackCancelled reaction here: sounds and
-- particles don't replicate on their own the way animations do, so every
-- client's copy of this controller reacts independently to the same
-- broadcast, each playing its own local copy of the character's own
-- Sound/ParticleEmitter instances (correctly spatialised per listener).
-- Only the knockout blind screen and input freeze are local-player-only,
-- since those are the local player's own screen and controls.
--
-- M3-FIX3 (Bryan, 2026-09-28): AttackCancelled{reason} splits two ways --
-- "cancelled" (a right-click before the first wind-up marker) flashes the
-- character's old "Cancel" Highlight; "interrupted" (hit mid wind-up)
-- plays the same stagger reaction as a landed Hit and stops that
-- character's fist track if the local CombatController (their own, on
-- their own machine) left one playing. This file has no access to
-- CombatController's private swing state -- for the interrupted case it
-- finds the actual playing track itself, generically, by animation id.
--
-- Assets reused:
--   Cloned onto every character's Torso/Head already, by CharacterService
--   (M2-01) -- this file only finds and plays/emits them:
--     LightHitSound1-3, LightHitSoundFin, MissSound1-3, BlockSound1-2,
--     BlockBroken, Parry (Sound); HitParticle, BlockParticle,
--     BlockBreakParticle (ParticleEmitter, under Torso's CenterHook
--     attachment); Confusion (ParticleEmitter, under Head.HairAttachment).
--     Sparks1-2 are a PARRY particle only (old InteractionsDesign.server.
--     luau:96-97, `:Emit(10)` on a successful parry), not a plain Hit --
--     the old game never emitted them on an ordinary hit.
--   Cloned fresh per use here (not pre-attached by CharacterService):
--     ReplicatedFirst.VFX.HitEffects.ParryCircle
--     ReplicatedFirst.VFX.MiscEffects.DashTrail
--   Stagger animations (Hit reaction and the Stunned pose below), old
--   PhysicalHandler.client.luau ids (Action4): rbxassetid://15430342283,
--   15430496352, 15430593084 (picked with no immediate repeat -- AUDIT
--   L11's "no repeat doesn't work" fix).
--   Block-hit flinch (BlockStagger1Track, old default priority/speed):
--   rbxassetid://15430386843, played on a Blocked reaction -- the old
--   game's "Hit while your Block marker is still up" case, which the new
--   CombatService turns into its own Blocked event instead of a Hit.
--   Block-break animation (BlockBreakTrack, old default priority/speed):
--   rbxassetid://86794346470329, played on a BlockBroken reaction.
--   Knockout screen: ReplicatedFirst.GUI.MiscGUI.Blind
--
-- Ragdoll (ReplicatedStorage.Modules.Ragdoll) is NOT called from here.
-- Its RagdollCharacter/UnRagdollCharacter build the actual joints/
-- constraints that make a body go limp; the old game only ever ran that
-- on the SERVER (EffectsService.server.luau), where a single authoritative
-- call replicates structurally to every client for free. Having every
-- observing client independently build the same joints on a character
-- they don't own would create redundant, unowned constraints that never
-- actually simulate for anyone but the character's own network owner --
-- so the physics would only ever look right on the ragdolled player's own
-- screen. This file only does the LOCAL PLAYER's own Humanoid state flip
-- (Physics <-> GettingUp, same as the old ragdollEvent's client half) and
-- the blind screen/input freeze. FLAG FOR THE LEAD: confirm the joint
-- creation itself is StatusService's job (M3-01), same as the old
-- EffectsService.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared:WaitForChild("Log"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Config = require(Shared:WaitForChild("Config"))

local log = Log.new("EffectsController")
local player = Players.LocalPlayer

local VFX = ReplicatedFirst:WaitForChild("VFX")
local HitEffects = VFX:WaitForChild("HitEffects")
local MiscEffects = VFX:WaitForChild("MiscEffects")
local CancelTemplate = MiscEffects:WaitForChild("Cancel")
local BlindTemplate = ReplicatedFirst:WaitForChild("GUI"):WaitForChild("MiscGUI"):WaitForChild("Blind")

local EffectsController = {}

-- Shared/Data/Combat.luau (M3-01) isn't built yet, so the real per-move
-- hit time isn't available here. Until it lands, a flat grace period
-- (close to the old m1Recover) decides when a swing counts as a miss.
-- FLAG FOR THE LEAD: replace with the move's real hitTime + 0.1s once
-- M3-01 ships.
local MISS_GRACE_SECONDS = 0.7

local HIT_SOUND_COUNT = 3 -- LightHitSound1-3
local MISS_SOUND_COUNT = 3 -- MissSound1-3
local BLOCK_SOUND_COUNT = 2 -- BlockSound1-2
local PARRY_HITSTOP_SECONDS = 0.1
local DASH_TRAIL_SECONDS = 0.3

local STAGGER_IDS = {
	"rbxassetid://15430342283",
	"rbxassetid://15430496352",
	"rbxassetid://15430593084",
}
local STAGGER_SPEED = 0.8
local BLOCK_STAGGER_ID = "rbxassetid://15430386843"
local BLOCK_BREAK_ID = "rbxassetid://86794346470329"
local STUNNED_POLL_SECONDS = 0.15

-- Same ids as CombatController's ANIMATION_IDS.Fist/Dagger. Duplicated
-- (not required from there) because CombatController's swing track is
-- private, per-local-character state; this only needs the id to find
-- WHICHEVER client's copy is actually playing on a given Animator, not a
-- reference to it.
local SWING_ANIMATION_IDS = {
	["rbxassetid://125726557974534"] = true,
	["rbxassetid://115894342135428"] = true,
}

-- ==================== per-character caches (weak keys: no manual cleanup needed) ====================

type BlockReactionTracks = { blockStagger: AnimationTrack, blockBreak: AnimationTrack }

-- One swing's miss-sound bookkeeping: `generation` invalidates any still-
-- pending checks from a PREVIOUS swing on this character (so a fast
-- second attack can't play a miss sound for the first one after the
-- fact), `hit` marks which punch indices already landed for THIS swing.
type SwingMissState = { generation: number, hit: { [number]: boolean } }

local lastRandomIndex = (setmetatable({}, { __mode = "k" }) :: any) :: { [Instance]: { [string]: number } }
local staggerTracksByCharacter = (setmetatable({}, { __mode = "k" }) :: any) :: { [Instance]: { AnimationTrack } }
local blockReactionTracksByCharacter = (setmetatable({}, { __mode = "k" }) :: any) :: { [Instance]: BlockReactionTracks }
local swingMissState = (setmetatable({}, { __mode = "k" }) :: any) :: { [Instance]: SwingMissState }
local stunnedWatcherRunning = (setmetatable({}, { __mode = "k" }) :: any) :: { [Instance]: boolean }

local function pickIndex(character: Instance, key: string, count: number): number
	local perCharacter = lastRandomIndex[character]
	if not perCharacter then
		perCharacter = {}
		lastRandomIndex[character] = perCharacter
	end
	local previous = perCharacter[key]
	local index = math.random(1, count)
	if count > 1 then
		while index == previous do
			index = math.random(1, count)
		end
	end
	perCharacter[key] = index
	return index
end

-- ==================== sound / particle lookup (already attached by CharacterService) ====================

local function playSound(character: Instance, name: string)
	local sound = character:FindFirstChild(name, true)
	if sound and sound:IsA("Sound") then
		sound:Play()
	end
end

local function emitParticle(character: Instance, name: string, count: number)
	local emitter = character:FindFirstChild(name, true)
	if emitter and emitter:IsA("ParticleEmitter") then
		emitter:Emit(count)
	end
end

local function burstParticle(template: Instance, parent: Instance, count: number, lifetime: number)
	if not template:IsA("ParticleEmitter") then
		return
	end
	local clone = template:Clone()
	clone.Parent = parent
	clone:Emit(count)
	Debris:AddItem(clone, lifetime)
end

-- ==================== stagger (Hit reaction) ====================

local function getStaggerTracks(character: Instance): { AnimationTrack }?
	local existing = staggerTracksByCharacter[character]
	if existing then
		return existing
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return nil
	end

	local tracks = table.create(#STAGGER_IDS)
	for _, id in STAGGER_IDS do
		local animation = Instance.new("Animation")
		animation.AnimationId = id
		local track = animator:LoadAnimation(animation)
		track.Priority = Enum.AnimationPriority.Action4
		table.insert(tracks, track)
	end
	staggerTracksByCharacter[character] = tracks
	return tracks
end

local function playStagger(character: Instance)
	local tracks = getStaggerTracks(character)
	if not tracks then
		return
	end
	local track = tracks[pickIndex(character, "stagger", #tracks)]
	track:Play()
	track:AdjustSpeed(STAGGER_SPEED)
end

-- ==================== block-hit flinch / block-break (Blocked, BlockBroken reactions) ====================

local function getBlockReactionTracks(character: Instance): BlockReactionTracks?
	local existing = blockReactionTracksByCharacter[character]
	if existing then
		return existing
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return nil
	end

	local function load(id: string): AnimationTrack
		local animation = Instance.new("Animation")
		animation.AnimationId = id
		-- Old PhysicalHandler never set a Priority for either of these,
		-- so both keep Roblox's default (unlike the Action2/3/4 tracks
		-- elsewhere in this file, which explicitly reused the old ones).
		return animator:LoadAnimation(animation)
	end

	local tracks = { blockStagger = load(BLOCK_STAGGER_ID), blockBreak = load(BLOCK_BREAK_ID) }
	blockReactionTracksByCharacter[character] = tracks
	return tracks
end

-- ==================== hit-stop (Parried reaction) ====================

local function applyHitStop(character: Instance, duration: number)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	for _, track in animator:GetPlayingAnimationTracks() do
		local originalSpeed = track.Speed
		track:AdjustSpeed(0)
		task.delay(duration, function()
			if track.IsPlaying then
				track:AdjustSpeed(originalSpeed)
			end
		end)
	end
end

-- ==================== AttackCancelled reactions (M3-FIX3) ====================

local function flashCancelHighlight(character: Instance)
	local highlight = character:FindFirstChild("Cancel")
	if not (highlight and highlight:IsA("Highlight")) then
		if not CancelTemplate:IsA("Highlight") then
			return
		end
		local clone = CancelTemplate:Clone()
		clone.Parent = character
		highlight = clone
	end

	local cancelHighlight = highlight :: Highlight
	cancelHighlight.Enabled = true
	task.delay(Config.Combat.CancelFlashSeconds, function()
		if cancelHighlight.Parent then
			cancelHighlight.Enabled = false
		end
	end)
end

-- Finds and stops whichever AnimationTrack on this character's Animator
-- is actually the fist swing, wherever it came from -- see this file's
-- header comment on why it can't just hold CombatController's reference.
local function stopSwingTrackIfPlaying(character: Instance, fadeTime: number?)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	for _, track in animator:GetPlayingAnimationTracks() do
		local animation = track.Animation
		if animation and SWING_ANIMATION_IDS[animation.AnimationId] then
			track:Stop(fadeTime)
		end
	end
end

-- ==================== stunned pose (spec item 5) ====================
-- While `Stunned` is true and nothing else (a swing, block or dash) is
-- currently animating the character, hold one of the same stagger poses
-- used for the Hit reaction above; stop the moment Stunned clears or
-- something higher-priority takes over. Polled rather than event-driven
-- so the watcher is fully bounded to the stunned window: nothing is left
-- listening once Stunned goes false, unlike hooking every future
-- AnimationTrack's Stopped signal for the rest of the character's life.

local function isCombatAnimationPlaying(animator: Animator, ignoreTrack: AnimationTrack?): boolean
	for _, track in animator:GetPlayingAnimationTracks() do
		if track ~= ignoreTrack and track.Priority.Value >= Enum.AnimationPriority.Action.Value then
			return true
		end
	end
	return false
end

local function watchStunnedPose(character: Instance)
	if stunnedWatcherRunning[character] then
		return
	end
	stunnedWatcherRunning[character] = true

	task.spawn(function()
		local activeTrack: AnimationTrack? = nil
		while character.Parent and character:GetAttribute("Stunned") == true do
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
			local tracks = if animator then getStaggerTracks(character) else nil
			if animator and tracks then
				if isCombatAnimationPlaying(animator, activeTrack) then
					if activeTrack then
						activeTrack.Looped = false
						activeTrack:Stop()
						activeTrack = nil
					end
				elseif not activeTrack then
					local track = tracks[pickIndex(character, "stunnedPose", #tracks)]
					track.Looped = true
					track:AdjustSpeed(STAGGER_SPEED)
					track:Play()
					activeTrack = track
				end
			end
			task.wait(STUNNED_POLL_SECONDS)
		end

		if activeTrack then
			activeTrack.Looped = false
			activeTrack:Stop()
		end
		stunnedWatcherRunning[character] = nil
	end)
end

local function wireStunnedWatcher(character: Instance)
	character:GetAttributeChangedSignal("Stunned"):Connect(function()
		if character:GetAttribute("Stunned") == true then
			watchStunnedPose(character)
		end
	end)
	if character:GetAttribute("Stunned") == true then
		watchStunnedPose(character)
	end
end

-- ==================== knockout: local player only ====================

local currentCharacter: Model? = nil
local activeBlindGui: ScreenGui? = nil
local frozenControls: any = nil

local function getControls(): any
	local playerScripts = player:FindFirstChild("PlayerScripts") :: PlayerScripts?
	local playerModule = playerScripts and playerScripts:FindFirstChild("PlayerModule")
	if not playerModule then
		log:Warn("PlayerScripts.PlayerModule missing; Controls won't be disabled")
		return nil
	end
	local ok, moduleOrErr = pcall(require, playerModule)
	if not ok then
		log:Warn("require(PlayerModule) failed: " .. tostring(moduleOrErr))
		return nil
	end
	local okControls, controlsOrErr = pcall(function()
		return moduleOrErr:GetControls()
	end)
	if not okControls then
		log:Warn("PlayerModule:GetControls() failed: " .. tostring(controlsOrErr))
		return nil
	end
	return controlsOrErr
end

local function freezeLocalInput()
	if frozenControls then
		return
	end
	local controls = getControls()
	if not controls then
		return
	end
	local ok, err = pcall(function()
		controls:Disable()
	end)
	if ok then
		frozenControls = controls
	else
		log:Warn("Controls:Disable() failed: " .. tostring(err))
	end
end

local function unfreezeLocalInput()
	if not frozenControls then
		return
	end
	local controls = frozenControls
	frozenControls = nil
	local ok, err = pcall(function()
		controls:Enable()
	end)
	if not ok then
		log:Warn("Controls:Enable() failed: " .. tostring(err))
	end
end

local function showBlindScreen()
	if activeBlindGui then
		return
	end
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end
	local clone = BlindTemplate:Clone() :: ScreenGui
	clone.Parent = playerGui
	activeBlindGui = clone
end

local function hideBlindScreen()
	if activeBlindGui then
		activeBlindGui:Destroy()
		activeBlindGui = nil
	end
end

-- The old ragdollEvent's client half: only the character's own owning
-- client flips its Humanoid between Physics (slumped) and GettingUp.
local function setRagdollHumanoidState(character: Instance, knocked: boolean)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	if knocked then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	else
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
end

local function teardownCharacter()
	hideBlindScreen()
	unfreezeLocalInput()
	currentCharacter = nil
end

local function onCharacterAdded(character: Model)
	teardownCharacter()
	currentCharacter = character
	wireStunnedWatcher(character)
end

-- Other players' Stunned pose: same watcher, but these characters never
-- go through teardownCharacter/currentCharacter (that's local-player-only
-- knockout state), so this is the only wiring they need.
local function onOtherCharacterAdded(character: Model)
	wireStunnedWatcher(character)
end

-- ==================== CombatEvent reactions ====================

-- M3-FIX3: a swing can carry several punches (`punchCount`), each with
-- its own Hit report (`punchIndex`); a punch that gets no Hit within its
-- own window plays its own miss sound, independent of the others. Staggers
-- each punch's check by MISS_GRACE_SECONDS * punchIndex, since the real
-- per-punch hitWindow (Shared/Data/Combat.luau, server-only) isn't
-- available here -- same flagged fallback as before, just applied per
-- punch instead of once per swing.
local function onSwing(character: Instance, punchCount: number)
	local previous = swingMissState[character]
	local generation = (previous and previous.generation or 0) + 1
	local state: SwingMissState = { generation = generation, hit = {} }
	swingMissState[character] = state

	for punchIndex = 1, punchCount do
		task.delay(MISS_GRACE_SECONDS * punchIndex, function()
			if swingMissState[character] == state and not state.hit[punchIndex] then
				playSound(character, "MissSound" .. pickIndex(character, "miss", MISS_SOUND_COUNT))
			end
		end)
	end
end

local function onHit(data: any)
	local attacker = data.attacker
	if typeof(attacker) == "Instance" then
		-- The punch landed; mark it so its own miss check is a no-op.
		local state = swingMissState[attacker]
		if state then
			local punchIndex = if typeof(data.punchIndex) == "number" then data.punchIndex else 1
			state.hit[punchIndex] = true
		end
	end

	local target = data.target
	if typeof(target) ~= "Instance" then
		return
	end

	if data.finisher == true then
		playSound(target, "LightHitSoundFin")
	else
		playSound(target, "LightHitSound" .. pickIndex(target, "hit", HIT_SOUND_COUNT))
	end
	emitParticle(target, "HitParticle", 1)
	playStagger(target)
end

local function onBlocked(data: any)
	local target = data.target
	if typeof(target) ~= "Instance" then
		return
	end
	playSound(target, "BlockSound" .. pickIndex(target, "block", BLOCK_SOUND_COUNT))
	emitParticle(target, "BlockParticle", 1)

	local tracks = getBlockReactionTracks(target)
	if tracks then
		tracks.blockStagger:Play()
	end
end

local function onParried(data: any)
	local target = data.target
	if typeof(target) == "Instance" then
		playSound(target, "Parry")
		emitParticle(target, "Sparks1", 10)
		emitParticle(target, "Sparks2", 10)
		local torso = target:FindFirstChild("Torso")
		if torso then
			burstParticle(HitEffects:WaitForChild("ParryCircle"), torso, 1, 1)
		end
	end

	local attacker = data.attacker
	if typeof(attacker) == "Instance" then
		applyHitStop(attacker, PARRY_HITSTOP_SECONDS)
	end
end

local function onBlockBroken(data: any)
	local target = data.target
	if typeof(target) ~= "Instance" then
		return
	end
	playSound(target, "BlockBroken")
	emitParticle(target, "BlockBreakParticle", 15)
	emitParticle(target, "Confusion", 5)

	local tracks = getBlockReactionTracks(target)
	if tracks then
		tracks.blockBreak:Play()
	end
end

local function onKnocked(data: any)
	local target = data.target
	if typeof(target) ~= "Instance" or target ~= currentCharacter then
		return
	end
	showBlindScreen()
	freezeLocalInput()
	setRagdollHumanoidState(target, true)
end

local function onRecovered(data: any)
	local target = data.target
	if typeof(target) ~= "Instance" or target ~= currentCharacter then
		return
	end
	hideBlindScreen()
	unfreezeLocalInput()
	setRagdollHumanoidState(target, false)
end

local function onAttackCancelled(data: any)
	local character = data.character
	if typeof(character) ~= "Instance" then
		return
	end
	if data.reason == "cancelled" then
		flashCancelHighlight(character)
	elseif data.reason == "interrupted" then
		playStagger(character)
		stopSwingTrackIfPlaying(character, 0.1)
	end
end

local function onDash(data: any)
	local character = data.character
	if typeof(character) ~= "Instance" then
		return
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local template = MiscEffects:FindFirstChild("DashTrail")
	if not rootPart or not (template and template:IsA("Trail")) then
		return
	end

	local attachmentFront = Instance.new("Attachment")
	attachmentFront.Position = Vector3.new(0, 0, -rootPart.Size.Z / 2)
	attachmentFront.Parent = rootPart

	local attachmentBack = Instance.new("Attachment")
	attachmentBack.Position = Vector3.new(0, 0, rootPart.Size.Z / 2)
	attachmentBack.Parent = rootPart

	local trail = (template :: Trail):Clone()
	trail.Attachment0 = attachmentFront
	trail.Attachment1 = attachmentBack
	trail.Enabled = true
	trail.Parent = rootPart

	Debris:AddItem(attachmentFront, DASH_TRAIL_SECONDS)
	Debris:AddItem(attachmentBack, DASH_TRAIL_SECONDS)
	Debris:AddItem(trail, DASH_TRAIL_SECONDS)
end

-- Run's camera zoom is CombatController's job (driven by the `Running`
-- attribute); reacting to it here too would fight the same FieldOfView
-- tween from two controllers at once.
local function onCombatEvent(kind: any, data: any)
	if typeof(kind) ~= "string" or typeof(data) ~= "table" then
		log:Warn("CombatEvent: unexpected payload")
		return
	end

	if kind == "Swing" then
		local character = data.character
		if typeof(character) == "Instance" then
			local punchCount = if typeof(data.punchCount) == "number" then data.punchCount else 1
			onSwing(character, punchCount)
		end
	elseif kind == "Hit" then
		onHit(data)
	elseif kind == "Blocked" then
		onBlocked(data)
	elseif kind == "Parried" then
		onParried(data)
	elseif kind == "BlockBroken" then
		onBlockBroken(data)
	elseif kind == "Knocked" then
		onKnocked(data)
	elseif kind == "Recovered" then
		onRecovered(data)
	elseif kind == "AttackCancelled" then
		onAttackCancelled(data)
	elseif kind == "Dash" then
		onDash(data)
	end
end

function EffectsController:Init() end

function EffectsController:Start()
	Remotes.Client.On("CombatEvent", onCombatEvent)

	player.CharacterAdded:Connect(onCharacterAdded)
	player.CharacterRemoving:Connect(teardownCharacter)
	if player.Character then
		onCharacterAdded(player.Character)
	end

	local function wireOtherPlayer(otherPlayer: Player)
		if otherPlayer == player then
			return
		end
		otherPlayer.CharacterAdded:Connect(onOtherCharacterAdded)
		if otherPlayer.Character then
			onOtherCharacterAdded(otherPlayer.Character)
		end
	end
	for _, otherPlayer in Players:GetPlayers() do
		wireOtherPlayer(otherPlayer)
	end
	Players.PlayerAdded:Connect(wireOtherPlayer)

	log:Info("ready")
end

return EffectsController
