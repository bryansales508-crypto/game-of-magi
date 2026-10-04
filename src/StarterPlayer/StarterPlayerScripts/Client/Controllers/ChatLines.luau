--!strict
-- One client helper for local-only chat system lines (RBXGeneral). Shared by the controllers that
-- tell the player something in chat; it has no Init/Start, so Main just requires it.

local TextChatService = game:GetService("TextChatService")

local ChatLines = {}

-- Shows `text` as a system line in the general channel; silent if the channel is missing.
function ChatLines.Post(text: string)
	local channels = TextChatService:FindFirstChild("TextChannels")
	local general = channels and channels:FindFirstChild("RBXGeneral")
	if general ~= nil and general:IsA("TextChannel") then
		general:DisplaySystemMessage(text)
	end
end

return ChatLines
