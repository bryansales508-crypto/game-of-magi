--!strict
-- Combat feedback: hit/block/parry/block-break sounds and particles, the miss whiff, dash trail, bleed
-- visuals, stagger and stunned poses, and the local player's knockout blind screen and input freeze.
-- Driven by the server's CombatEvent broadcasts and status attributes; the server decides every hit, this
-- file only reacts. The swing/dash/block-pose/run-zoom half is CombatController.
-- Every character gets its reactions here (sounds and particles don't replicate), each client playing its
-- own copy of the character's Sound/ParticleEmitter instances; only the blind screen and input freeze are
-- local-player-only.
-- AttackCancelled{reason}: "cancelled" flashes the character's "Cancel" Highlight; "interrupted" plays the
-- stagger and stops any fist swing track left playing.
-- Bleed{target, stacks} and the `Bleed` attribute add/remove bleed particles and the cut decal by stack
-- count; KnockedBack{target} emits the hit particle. There is no camera shake.
-- Assets already cloned onto each Torso/Head by CharacterService: LightHitSound1-3, LightHitSoundFin,
-- MissSound1-3, BlockSound1-2, BlockBroken, Parry; HitParticle, BlockParticle, BlockBreakParticle (under
-- Torso's CenterHook), Confusion (Head.HairAttachment); Sparks1-2 are parry-only. Cloned per use:
-- VFX.HitEffects.ParryCircle, VFX.MiscEffects.DashTrail, GUI.MiscGUI.Blind.
-- Ragdoll joints are built server-side by StatusService; this file only flips the local Humanoid state.

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
local StatusEffects = VFX:WaitForChild("StatusEffects")
local CancelTemplate = MiscEffects:WaitForChild("Cancel")
local BlindTemplate = ReplicatedFirst:WaitForChild("GUI"):WaitForChild("MiscGUI"):WaitForChild("Blind")

local EffectsController = {}

local HIT_SOUND_COUNT = 3 -- LightHitSound1-3
local MISS_SOUND_COUNT = 3 -- MissSound1-3
local BLOCK_SOUND_COUNT = 2 -- BlockSound1-2
local PARRY_HITSTOP_SECONDS = 0.1

local STAGGER_IDS = {
	"rbxassetid://15430342283",
	"rbxassetid://15430496352",
	"rbxassetid://15430593084",
}
local STAGGER_SPEED = 0.8
local BLOCK_STAGGER_ID = "rbxassetid://15430386843"
local BLOCK_BREAK_ID = "rbxassetid://86794346470329"
local STUNNED_POLL_SECONDS = 0.15

-- Combo animation ids, used to find whichever swing track is playing on any Animator.
local SWING_ANIMATION_IDS: { [string]: boolean } = {}
local comboAnimations: { [string]: string } = Config.Combat.ComboAnimations
for _, id in comboAnimations do
	if id ~= "" then
		SWING_ANIMATION_IDS[id] = true
	end
end

-- ReplicatedFirst.VFX.StatusEffects: BleedDroplet1-2 are ParticleEmitters, BleedCut a Part with a Decal.
local BLEED_DROPLET_NAMES = { "BleedDroplet1", "BleedDroplet2" }


type BlockReactionTracks = { blockStagger: AnimationTrack, blockBreak: AnimationTrack }

-- One bleed particle with its authored Rate (`baseRate`), so scaling by stacks never compounds.
type BleedEmitter = { emitter: ParticleEmitter, baseRate: number }
type BleedVisuals = { emitters: { BleedEmitter }, cutPart: BasePart? }

local lastRandomIndex = (setmetatable({}, { __mode = "k" }) :: any) :: { [Instance]: { [string]: number } }
local staggerTracksByCharacter = (setmetatable({}, { __mode = "k" }) :: any) :: { [Instance]: { AnimationTrack } }
local blockReactionTracksByCharacter = (setmetatable({}, { __mode = "k" }) :: any) :: { [Instance]: BlockReactionTracks }
local stunnedWatcherRunning = (setmetatable({}, { __mode = "k" }) :: any) :: { [Instance]: boolean }
local bleedVisualsByCharacter = (setmetatable({}, { __mode = "k" }) :: any) :: { [Instance]: BleedVisuals }

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
-- Neither track sets a Priority; both keep Roblox's default.
		return animator:LoadAnimation(animation)
	end

	local tracks = { blockStagger = load(BLOCK_STAGGER_ID), blockBreak = load(BLOCK_BREAK_ID) }
	blockReactionTracksByCharacter[character] = tracks
	return tracks
end


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

-- Finds and stops whichever AnimationTrack on this character's Animator is the fist swing, by animation id
-- (CombatController's own track reference is private).
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


local function clearBleedVisual(character: Instance)
	local visuals = bleedVisualsByCharacter[character]
	if not visuals then
		return
	end
	bleedVisualsByCharacter[character] = nil
	for _, info in visuals.emitters do
		info.emitter:Destroy()
	end
	if visuals.cutPart then
		visuals.cutPart:Destroy()
	end
end

local function buildBleedVisual(torso: BasePart): BleedVisuals
	local emitters: { BleedEmitter } = {}
	for _, name in BLEED_DROPLET_NAMES do
		local template = StatusEffects:FindFirstChild(name)
		if template and template:IsA("ParticleEmitter") then
			local clone = template:Clone()
			clone.Parent = torso
			table.insert(emitters, { emitter = clone, baseRate = template.Rate })
		end
	end

	local cutPart: BasePart? = nil
	local cutTemplate = StatusEffects:FindFirstChild("BleedCut")
	if cutTemplate and cutTemplate:IsA("BasePart") then
		local clone = cutTemplate:Clone()
		clone.Anchored = false
		clone.CanCollide = false
		clone.Massless = true
		clone.CFrame = torso.CFrame
		clone.Parent = torso
		local weld = Instance.new("Weld")
		weld.Part0 = torso
		weld.Part1 = clone
		weld.Parent = clone
		cutPart = clone
	end

	return { emitters = emitters, cutPart = cutPart }
end

-- Each emitter's Rate scales off its authored Rate (`baseRate`), not its last-updated value.
local function updateBleedVisual(character: Instance, stacks: number)
	if stacks <= 0 then
		clearBleedVisual(character)
		return
	end

	local torso = character:FindFirstChild("Torso")
	if not (torso and torso:IsA("BasePart")) then
		return
	end

	local visuals = bleedVisualsByCharacter[character]
	if not visuals then
		visuals = buildBleedVisual(torso)
		bleedVisualsByCharacter[character] = visuals
		-- NPC dummies are not Players, so there is no CharacterRemoving; Destroying fires once for any removed
		-- character and drops its bookkeeping entry.
		character.Destroying:Connect(function()
			clearBleedVisual(character)
		end)
	end

	for _, info in visuals.emitters do
		info.emitter.Enabled = true
		info.emitter.Rate = info.baseRate * stacks
	end
end

-- While `Stunned` is true and nothing else is animating the character, hold a stagger pose. Polled so
-- nothing keeps listening once Stunned clears. `LightStunned` has no pose.

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

-- Per-character attribute-driven reactions not tied to a CombatEvent: the Stunned pose and the Bleed visual
-- (watching the attribute covers characters that already have stacks).
local function wireCombatAttributeWatchers(character: Instance)
	character:GetAttributeChangedSignal("Stunned"):Connect(function()
		if character:GetAttribute("Stunned") == true then
			watchStunnedPose(character)
		end
	end)
	if character:GetAttribute("Stunned") == true then
		watchStunnedPose(character)
	end

	character:GetAttributeChangedSignal("Bleed"):Connect(function()
		local bleed = character:GetAttribute("Bleed")
		updateBleedVisual(character, if typeof(bleed) == "number" then bleed else 0)
	end)
	local initialBleed = character:GetAttribute("Bleed")
	if typeof(initialBleed) == "number" and initialBleed > 0 then
		updateBleedVisual(character, initialBleed)
	end
end


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

-- Only the owning client flips its Humanoid between Physics (slumped) and GettingUp.
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
	wireCombatAttributeWatchers(character)
end

-- Other players: the same watchers, without the local-player-only knockout state.
local function onOtherCharacterAdded(character: Model)
	wireCombatAttributeWatchers(character)
end


-- CombatEvent "Miss" {attacker, hitIndex} marks a swing that found nobody; the whiff sound plays then.
local function onMiss(data: any)
	local attacker = data.attacker
	if typeof(attacker) ~= "Instance" then
		return
	end
	playSound(attacker, "MissSound" .. pickIndex(attacker, "miss", MISS_SOUND_COUNT))
end

local function onHit(data: any)
	local target = data.target
	if typeof(target) ~= "Instance" then
		return
	end

	-- Every landed hit is a Light: ordinary hit sound and particle, no stagger.
	playSound(target, "LightHitSound" .. pickIndex(target, "hit", HIT_SOUND_COUNT))
	emitParticle(target, "HitParticle", 1)
end

-- A blocked feint arrives as a normal Blocked event.
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

-- Applies the Bleed update straight from the broadcast rather than waiting for the attribute to replicate.
local function onBleed(data: any)
	local target = data.target
	if typeof(target) ~= "Instance" then
		return
	end
	local stacks: number
	if typeof(data.stacks) == "number" then
		stacks = data.stacks
	else
		local bleed = target:GetAttribute("Bleed")
		stacks = if typeof(bleed) == "number" then bleed else 0
	end
	updateBleedVisual(target, stacks)
end

local function onKnockedBack(data: any)
	local target = data.target
	if typeof(target) ~= "Instance" then
		return
	end
	emitParticle(target, "HitParticle", 1)
end

local warnedDashSound = false

-- Dash whoosh, played from the dasher's body so nearby players hear it spatialised.
local function playDashSound(rootPart: BasePart)
	local sfx = ReplicatedFirst:FindFirstChild("SFX")
	local combatSounds = sfx and sfx:FindFirstChild("CombatSounds")
	local template = combatSounds and combatSounds:FindFirstChild(Config.World.Sfx.Dash)
	if template == nil or not template:IsA("Sound") then
		if not warnedDashSound then
			warnedDashSound = true
			log:Warn("dash sound missing: ReplicatedFirst.SFX.CombatSounds." .. Config.World.Sfx.Dash)
		end
		return
	end
	local sound = template:Clone()
	sound.Parent = rootPart
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	sound:Play()
	Debris:AddItem(sound, math.max(sound.TimeLength, 2) + 1)
end

local function onDash(data: any)
	local character = data.character
	if typeof(character) ~= "Instance" then
		return
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if rootPart and rootPart:IsA("BasePart") then
		playDashSound(rootPart)
	end
	local template = MiscEffects:FindFirstChild("DashTrail")
	if not rootPart or not (template and template:IsA("Trail")) then
		return
	end

	-- Dash lines: several thin copies of the DashTrail template, each from a random point inside the torso
	-- (scaled by Config.Combat.DashTrail), fanning out like speed lines.
	local lines = Config.Combat.DashTrail
	local rng = Random.new()
	local half = rootPart.Size / 2
	for _ = 1, lines.Count do
		local point = Vector3.new(
			rng:NextNumber(-half.X, half.X) * lines.Spread,
			rng:NextNumber(-half.Y, half.Y) * lines.Spread,
			rng:NextNumber(-half.Z, half.Z)
		)
		local halfWidth = rng:NextNumber(lines.MinWidth, lines.MaxWidth) / 2

		local top = Instance.new("Attachment")
		top.Position = point + Vector3.new(0, halfWidth, 0)
		top.Parent = rootPart

		local bottom = Instance.new("Attachment")
		bottom.Position = point - Vector3.new(0, halfWidth, 0)
		bottom.Parent = rootPart

		local trail = (template :: Trail):Clone()
		trail.Attachment0 = top
		trail.Attachment1 = bottom
		trail.Enabled = true
		trail.Parent = rootPart

		Debris:AddItem(top, lines.Seconds)
		Debris:AddItem(bottom, lines.Seconds)
		Debris:AddItem(trail, lines.Seconds)
	end
end

-- The Running camera zoom belongs to CombatController; reacting here too would fight its FieldOfView tween.
local function onCombatEvent(kind: any, data: any)
	if typeof(kind) ~= "string" or typeof(data) ~= "table" then
		log:Warn("CombatEvent: unexpected payload")
		return
	end

	if kind == "Hit" then
		onHit(data)
	elseif kind == "Miss" then
		onMiss(data)
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
	elseif kind == "Bleed" then
		onBleed(data)
	elseif kind == "KnockedBack" then
		onKnockedBack(data)
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
