--!strict
-- Creates the Net remote folder and wires up the handlers this milestone owns.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.new("NetService")

local NetService = {}

function NetService:Init()
	Remotes.Server.Init()

	Remotes.Server.On("DebugPing", function(player: Player, message: string)
		log:Debug(string.format("ping from %s: %s", player.Name, message))
	end)
end

function NetService:Start() end

return NetService
