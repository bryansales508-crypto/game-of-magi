--!strict
-- Small, composable validators for remote arguments.
--
-- Each Validate.* call is a factory: it takes options and returns a
-- Validator function. Validators are pure and side-effect free; calling
-- one just checks a value and reports why it failed, it never mutates
-- anything or throws.

export type Validator = (value: any) -> (boolean, string?)

local Validate = {}

local function isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

type NumberOptions = {
	min: number?,
	max: number?,
	integer: boolean?,
}

function Validate.number(options: NumberOptions?): Validator
	local opts: NumberOptions = options or {}
	return function(value: any): (boolean, string?)
		if type(value) ~= "number" then
			return false, "expected a number"
		end
		if not isFinite(value) then
			return false, "number must be finite"
		end
		if opts.integer and math.floor(value) ~= value then
			return false, "expected an integer"
		end
		if opts.min ~= nil and value < opts.min then
			return false, string.format("below minimum %s", tostring(opts.min))
		end
		if opts.max ~= nil and value > opts.max then
			return false, string.format("above maximum %s", tostring(opts.max))
		end
		return true
	end
end

type StringOptions = {
	maxLen: number,
	oneOf: { string }?,
}

function Validate.string(options: StringOptions): Validator
	return function(value: any): (boolean, string?)
		if type(value) ~= "string" then
			return false, "expected a string"
		end
		if #value > options.maxLen then
			return false, string.format("string longer than %d characters", options.maxLen)
		end
		if options.oneOf then
			for _, allowed in options.oneOf do
				if value == allowed then
					return true
				end
			end
			return false, "string not in allowed set"
		end
		return true
	end
end

function Validate.boolean(): Validator
	return function(value: any): (boolean, string?)
		if type(value) ~= "boolean" then
			return false, "expected a boolean"
		end
		return true
	end
end

type Vector3Options = {
	maxMagnitude: number?,
}

function Validate.vector3(options: Vector3Options?): Validator
	local opts: Vector3Options = options or {}
	return function(value: any): (boolean, string?)
		if typeof(value) ~= "Vector3" then
			return false, "expected a Vector3"
		end
		local v = value :: Vector3
		if not (isFinite(v.X) and isFinite(v.Y) and isFinite(v.Z)) then
			return false, "Vector3 components must be finite"
		end
		if opts.maxMagnitude ~= nil and v.Magnitude > opts.maxMagnitude then
			return false, "Vector3 magnitude too large"
		end
		return true
	end
end

function Validate.instance(className: string): Validator
	return function(value: any): (boolean, string?)
		if typeof(value) ~= "Instance" then
			return false, "expected an Instance"
		end
		if not (value :: Instance):IsA(className) then
			return false, string.format("expected an instance of %s", className)
		end
		return true
	end
end

function Validate.optional(validator: Validator): Validator
	return function(value: any): (boolean, string?)
		if value == nil then
			return true
		end
		return validator(value)
	end
end

function Validate.enum(list: { any }): Validator
	return function(value: any): (boolean, string?)
		for _, allowed in list do
			if value == allowed then
				return true
			end
		end
		return false, "value not in enum"
	end
end

return Validate
