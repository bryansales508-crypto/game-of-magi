-- Sinks input while the matching marker (FreezeInput, BigFreezeInput, ActionFreezeInput) sits in character.Effects,
-- and posts server-sent ForcedChat lines to the general chat channel.
local player = game.Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")
local torso = character:WaitForChild("Torso")

while character:WaitForChild("AppearenceLoaded").Value == false do task.wait() end

local effects = character:WaitForChild("Effects")

local ContextActionService = game:GetService("ContextActionService")
local FREEZE_ACTION = "freezeMovement"
local BIG_FREEZE_ACTION = "bigfreezeMovement"
local ACTION_FREEZE_ACTION = "actionfreezeMovement"

local forcedChatEvent = game.ReplicatedStorage.Remotes.MiscRemotes:WaitForChild("ForcedChat")
local textServ = game:GetService("TextChatService")
local speech = textServ:WaitForChild("TextChannels"):WaitForChild("RBXGeneral")

local cam = workspace.CurrentCamera

local frozeActions = {
	Enum.UserInputType.MouseButton1,
	unpack(Enum.PlayerActions:GetEnumItems()),
	Enum.UserInputType.MouseButton2
}

local bigfrozeAction = {Enum.UserInputType.MouseButton1,
	Enum.UserInputType.MouseButton3,
}
for _,v in Enum.KeyCode:GetEnumItems() do
	if v ~= Enum.KeyCode.LeftShift then
		table.insert(bigfrozeAction, v)
	end
end

local actionfrozeAction = {Enum.UserInputType.MouseButton1, Enum.UserInputType.MouseButton2}
for _,v in Enum.KeyCode:GetEnumItems() do
	if v == Enum.KeyCode.W or v == Enum.KeyCode.S or v == Enum.KeyCode.D or v == Enum.KeyCode.A  then
	else
		table.insert(actionfrozeAction, v)
	end
end

effects.ChildAdded:Connect(function(child)
	if child.Name == "FreezeInput" then
		ContextActionService:BindAction(
			FREEZE_ACTION,
			function() return Enum.ContextActionResult.Sink end,
			false,
			unpack(frozeActions)
		)
	end
end)

effects.ChildRemoved:Connect(function(child)
	if not effects:FindFirstChild("FreezeInput") then
		ContextActionService:UnbindAction(FREEZE_ACTION)
	end
end)

effects.ChildAdded:Connect(function(child)
	if child.Name == "BigFreezeInput" then
		ContextActionService:BindAction(
			BIG_FREEZE_ACTION,
			function() return Enum.ContextActionResult.Sink end,
			false,
			unpack(bigfrozeAction)
		)
	end
end)

effects.ChildRemoved:Connect(function(child)
	if child.name == "BigFreezeInput" then
		ContextActionService:UnbindAction(BIG_FREEZE_ACTION)
	end
end)

-- ActionFreezeInput sinks everything except the movement keys so the player can start moving again right after.
effects.ChildAdded:Connect(function(child)
	if child.Name == "ActionFreezeInput" then
		ContextActionService:BindAction(
			ACTION_FREEZE_ACTION,
			function() return Enum.ContextActionResult.Sink end,
			false,
			unpack(actionfrozeAction)
		)

		local con
		con = child.Destroying:Connect(function()
			ContextActionService:UnbindAction(ACTION_FREEZE_ACTION)
			con:Disconnect()
		end)
	end
end)


forcedChatEvent.OnClientEvent:Connect(function(msg)
	speech:SendAsync(msg)
end)