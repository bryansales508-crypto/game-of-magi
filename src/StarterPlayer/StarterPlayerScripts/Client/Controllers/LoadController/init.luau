--!strict
-- Shows the loading screen for every spawn (join and respawn) and holds it
-- up until the server reports the character is placed.
--
-- Server contract (PlayerService): Player:GetAttribute("JoinState") goes
-- "Loading" -> "Loaded" -> "Ready", and again "Loading" -> "Loaded" on every
-- respawn. This controller waits for "Loaded", fades out, then fires the
-- ClientReady event once per spawn.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared:WaitForChild("Log"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local log = Log.new("LoadController")

local STILL_LOADING_AFTER = 60

local player = Players.LocalPlayer

-- The LoadScreen ScreenGui is a sibling file (LoadScreen.rbxm) synced next
-- to this module, so it's already a child by the time this module runs.
local loadScreenTemplate = script:FindFirstChild("LoadScreen") :: ScreenGui?
if not loadScreenTemplate then
	log:Error("LoadScreen.rbxm is missing next to LoadController")
end

local LoadController = {}

-- Bumped on every CharacterAdded so a load sequence left over from a
-- previous spawn (e.g. a very fast respawn) gives up instead of fighting
-- the new one over the same PlayerGui or firing ClientReady twice.
local generation = 0

-- Waits for JoinState == "Loaded". Returns false if superseded by a newer
-- spawn (or the attribute stops changing because the player left) instead
-- of hanging forever.
local function waitForLoaded(myGeneration: number): boolean
	if player:GetAttribute("JoinState") == "Loaded" then
		return true
	end

	local changedSignal = player:GetAttributeChangedSignal("JoinState")
	local caller = coroutine.running()
	local settled = false
	local connection: RBXScriptConnection

	local function finish(result: boolean)
		if settled then
			return
		end
		settled = true
		connection:Disconnect()
		task.spawn(caller, result)
	end

	connection = changedSignal:Connect(function()
		if myGeneration ~= generation or player.Parent == nil then
			finish(false)
		elseif player:GetAttribute("JoinState") == "Loaded" then
			finish(true)
		end
	end)

	return coroutine.yield()
end

-- Plays the pulse (out <-> back) until a Cancel() ends it. Destroys both tweens
-- itself after its own Wait() calls have settled, rather than have the caller
-- destroy them out from under a pending Wait().
local function runPulse(pulseOut: Tween, pulseBack: Tween)
	while true do
		pulseOut:Play()
		if pulseOut.Completed:Wait() ~= Enum.PlaybackState.Completed then
			break
		end
		pulseBack:Play()
		if pulseBack.Completed:Wait() ~= Enum.PlaybackState.Completed then
			break
		end
	end
	pulseOut:Destroy()
	pulseBack:Destroy()
end

local function runLoadSequence(_character: Model)
	if not loadScreenTemplate then
		return
	end

	generation += 1
	local myGeneration = generation

	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

	-- A previous, superseded sequence may not have gotten to destroy its
	-- own screen yet (see the generation checks below); clear it first so
	-- the player never sees two loading screens stacked on top of each
	-- other.
	local leftover = playerGui:FindFirstChild(loadScreenTemplate.Name)
	if leftover then
		leftover:Destroy()
	end

	-- Shown before anything else runs, so the player never sees the
	-- character at its pre-teleport position.
	local gooey = loadScreenTemplate:Clone()
	gooey.Parent = playerGui

	local frame = gooey:WaitForChild("Frame")
	local imageLabel = frame:WaitForChild("ImageLabel") :: ImageLabel
	local textLabel = frame:FindFirstChild("TextLabel") :: TextLabel?

	local pulseOut = TweenService:Create(imageLabel, TweenInfo.new(5, Enum.EasingStyle.Linear), { ImageTransparency = 1 })
	local pulseBack = TweenService:Create(imageLabel, TweenInfo.new(5, Enum.EasingStyle.Linear), { ImageTransparency = 0.5 })
	task.spawn(runPulse, pulseOut, pulseBack)

	local warnThread = task.delay(STILL_LOADING_AFTER, function()
		if myGeneration ~= generation then
			return
		end
		if textLabel then
			textLabel.Text = "Still loading..."
		end
		log:Warn(string.format("JoinState still \"Loading\" after %ds for %s", STILL_LOADING_AFTER, player.Name))
	end)

	local loaded = waitForLoaded(myGeneration)
	task.cancel(warnThread)

	pulseOut:Cancel()
	pulseBack:Cancel()

	if myGeneration ~= generation then
		-- A newer spawn owns the screen now; leave it alone.
		return
	end

	if not loaded then
		-- The player left mid-load; nothing left to show.
		gooey:Destroy()
		return
	end

	local fadeIn = TweenService:Create(imageLabel, TweenInfo.new(1, Enum.EasingStyle.Linear), { ImageTransparency = 0 })
	fadeIn:Play()
	fadeIn.Completed:Wait()
	fadeIn:Destroy()

	task.wait(2)

	if myGeneration ~= generation then
		return
	end

	gooey:Destroy()
	Remotes.Client.Fire("ClientReady")
end

function LoadController:Init() end

function LoadController:Start()
	player.CharacterAdded:Connect(runLoadSequence)
	if player.Character then
		runLoadSequence(player.Character)
	end
end

return LoadController
