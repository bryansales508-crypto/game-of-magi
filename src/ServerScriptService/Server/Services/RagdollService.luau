--!strict
-- Ragdoll fold (M7-01, BUG-35). Replaces the legacy EffectsService.server.luau:
-- when Knocked turns on for ANY combatant StatusService knows (player or NPC,
-- wherever it lives in Workspace) its joints are built via the Ragdoll module;
-- when Knocked ends they are removed again.
--
-- Players: the owning client's EffectsController still flips the Humanoid
-- between Physics and GettingUp itself, so the server does not touch a
-- player's Humanoid state (and the old RagdollEvent remote is no longer fired).
-- NPCs have no client doing that, so the server sets the Humanoid state, exactly
-- like the old ragdollFunc did.
--
-- Also takes over the one other job EffectsService had for players: creating
-- character.Effects (once AppearenceLoaded is true) - StatusService, FaceControl
-- and the client's InputHandler all wait for that folder to exist.
--
-- Also writes the "Ragdoll" status (-> character.Effects.Ragdoll bridge marker)
-- alongside Knocked, because FaceControl reads that marker for the dazed face.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Ragdoll = require(ReplicatedStorage.Modules.Ragdoll)
local StatusService = require(script.Parent.StatusService)

local log = Log.new("RagdollService")

type Entry = {
	active: boolean,
	isNpc: boolean,
	ancestryConn: RBXScriptConnection?,
}

local entries: { [Model]: Entry } = {}
local connections: { RBXScriptConnection } = {}

local RagdollService = {}

local function humanoidOf(character: Model): Humanoid?
	return character:FindFirstChildOfClass("Humanoid")
end

local function release(character: Model, entry: Entry)
	if not entry.active then
		return
	end
	entry.active = false

	local ok, err = pcall(Ragdoll.UnRagdollCharacter, character)
	if not ok then
		log:Warn(string.format("UnRagdoll(%s) failed: %s", character.Name, tostring(err)))
	end

	if entry.isNpc then
		local humanoid = humanoidOf(character)
		if humanoid and humanoid.Parent ~= nil then
			humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
	end

	StatusService.Remove(character, "Ragdoll")
end

local function drop(character: Model)
	local entry = entries[character]
	if entry == nil then
		return
	end
	release(character, entry)
	entries[character] = nil
	if entry.ancestryConn then
		entry.ancestryConn:Disconnect()
	end
end

local function engage(character: Model)
	local entry = entries[character]
	if entry == nil then
		local newEntry: Entry = {
			active = false,
			isNpc = Players:GetPlayerFromCharacter(character) == nil,
			ancestryConn = nil,
		}
		newEntry.ancestryConn = character.AncestryChanged:Connect(function(_child, parent)
			if parent == nil then
				drop(character)
			end
		end)
		entries[character] = newEntry
		entry = newEntry
	end
	local current = entry :: Entry
	if current.active then
		return
	end
	current.active = true

	StatusService.Apply(character, "Ragdoll")

	if current.isNpc then
		local humanoid = humanoidOf(character)
		if humanoid then
			humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
			humanoid:ChangeState(Enum.HumanoidStateType.Physics)
		end
	end

	-- May yield briefly for a player whose appearance is still loading.
	local ok, err = pcall(Ragdoll.RagdollCharacter, character)
	if not ok then
		log:Warn(string.format("Ragdoll(%s) failed: %s", character.Name, tostring(err)))
	end

	-- Knocked ended while we were waiting: undo what we just built.
	if not current.active then
		pcall(Ragdoll.UnRagdollCharacter, character)
	end
end

local function onStatusChanged(character: Model, status: string, active: boolean)
	if status ~= "Knocked" then
		return
	end
	if active then
		engage(character)
	else
		local entry = entries[character]
		if entry then
			release(character, entry)
		end
	end
end

-- Players only (NPC bridge folders are StatusService's own fallback). Same
-- timing the old EffectsService used: after AppearenceLoaded flips true. Gives
-- up waiting after EFFECTS_WAIT seconds and creates it anyway so nothing that
-- waits on it hangs forever; stops if the character leaves first.
local EFFECTS_WAIT = 60

local function ensureEffectsFolder(character: Model)
	task.spawn(function()
		local deadline = os.clock() + EFFECTS_WAIT
		local flag = character:WaitForChild("AppearenceLoaded", EFFECTS_WAIT)
		if flag and flag:IsA("BoolValue") then
			while not flag.Value and os.clock() < deadline and character.Parent ~= nil do
				task.wait(0.1)
			end
		end
		if character.Parent == nil or character:FindFirstChild("Effects") ~= nil then
			return
		end
		local folder = Instance.new("Folder")
		folder.Name = "Effects"
		folder.Parent = character
	end)
end

local function watchPlayer(player: Player)
	table.insert(connections, player.CharacterAdded:Connect(ensureEffectsFolder))
	if player.Character then
		ensureEffectsFolder(player.Character)
	end
end

function RagdollService.IsRagdolled(character: Model): boolean
	local entry = entries[character]
	return entry ~= nil and entry.active
end

function RagdollService:Init()
	table.insert(connections, StatusService.Changed:Connect(onStatusChanged))
	table.insert(connections, Players.PlayerAdded:Connect(watchPlayer))
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	table.insert(
		connections,
		Players.PlayerRemoving:Connect(function(player: Player)
			if player.Character then
				drop(player.Character)
			end
		end)
	)
end

-- Disconnects the subscriptions and un-ragdolls everyone (unused at runtime).
function RagdollService.Stop()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	local characters: { Model } = {}
	for character in entries do
		table.insert(characters, character)
	end
	for _, character in characters do
		drop(character)
	end
end

return RagdollService
