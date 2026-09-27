--!strict
-- Tagged, level-filtered logger. This is the ONLY module allowed to call
-- print/warn; everything else should go through Log.new(tag).

local Config = require(script.Parent.Config)

export type Logger = {
	Debug: (self: Logger, ...any) -> (),
	Info: (self: Logger, ...any) -> (),
	Warn: (self: Logger, ...any) -> (),
	Error: (self: Logger, ...any) -> (),
}

type Level = "Debug" | "Info" | "Warn" | "Error"

local LEVEL_RANK: { [string]: number } = {
	Debug = 1,
	Info = 2,
	Warn = 3,
	Error = 4,
}

local function currentRank(): number
	return LEVEL_RANK[Config.Debug.LogLevel] or LEVEL_RANK.Info
end

local function safeToString(value: any): string
	if type(value) == "string" then
		return value
	end
	local ok, result = pcall(tostring, value)
	if ok then
		return result
	end
	return "<unstringable>"
end

local function formatArgs(...: any): string
	local count = select("#", ...)
	local parts: { string } = table.create(count)
	for i = 1, count do
		parts[i] = safeToString((select(i, ...)))
	end
	return table.concat(parts, " ")
end

local Logger = {}
Logger.__index = Logger

local function emit(self: any, level: Level, ...: any)
	if LEVEL_RANK[level] < currentRank() then
		return
	end

	local message = string.format("[%s] %s", self._tag, formatArgs(...))

	if level == "Debug" or level == "Info" then
		print(message)
	elseif level == "Warn" then
		warn("[WARN] " .. message)
	else
		local full = "[ERROR] " .. message
		if Config.IsStudio then
			full = full .. "\n" .. debug.traceback()
		end
		warn(full)
	end
end

function Logger:Debug(...: any)
	emit(self, "Debug", ...)
end

function Logger:Info(...: any)
	emit(self, "Info", ...)
end

function Logger:Warn(...: any)
	emit(self, "Warn", ...)
end

function Logger:Error(...: any)
	emit(self, "Error", ...)
end

local Log = {}

function Log.new(tag: string): Logger
	return setmetatable({ _tag = tag }, Logger) :: any
end

return Log
