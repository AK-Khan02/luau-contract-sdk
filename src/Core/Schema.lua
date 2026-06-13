--!strict

local SchemaValidation = require("./SchemaValidation")

export type ValidationResult = SchemaValidation.ValidationResult

export type Schema = {
	kind: string,
	[string]: any,
}

local Schema: any = {}

-- Default size ceilings so attacker-controlled fields on hot remotes cannot be
-- used for unbounded allocation. Pass `false` per field to opt out, or a number
-- to override.
local DEFAULT_STRING_MAX_LENGTH = 4096
local DEFAULT_ARRAY_MAX_ITEMS = 1024

local function ceilingFrom(option: any, default: number): number?
	if option == false then
		return nil
	end
	if option == nil then
		return default
	end
	return option
end

local function isArray(values: any): boolean
	if type(values) ~= "table" then
		return false
	end

	local count = 0
	for key in pairs(values) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false
		end
		count += 1
	end
	return count == #values
end

function Schema.any(): Schema
	return {
		kind = "any",
	}
end

function Schema.boolean(): Schema
	return {
		kind = "boolean",
	}
end

function Schema.number(options: any?): Schema
	return {
		kind = "number",
		min = options and options.min,
		max = options and options.max,
	}
end

function Schema.integer(minimum: number?, maximum: number?): Schema
	return {
		kind = "integer",
		min = minimum,
		max = maximum,
	}
end

function Schema.string(options: any?): Schema
	options = options or {}
	return {
		kind = "string",
		minLength = options.minLength,
		maxLength = ceilingFrom(options.maxLength, DEFAULT_STRING_MAX_LENGTH),
		pattern = options.pattern,
		description = options.description,
	}
end

function Schema.stringId(): Schema
	return Schema.string({
		minLength = 1,
		maxLength = 80,
		pattern = "^[%w_%-]+$",
		description = "string id",
	})
end

function Schema.oneOf(values: { any }): Schema
	if not isArray(values) then
		error("Schema.oneOf expects an array", 2)
	end

	local allowed = {}
	for _, value in ipairs(values) do
		allowed[value] = true
	end

	return {
		kind = "oneOf",
		values = values,
		allowed = allowed,
	}
end

function Schema.literal(expected: any): Schema
	return {
		kind = "literal",
		expected = expected,
	}
end

function Schema.optional(schema: any): Schema
	return {
		kind = "optional",
		schema = schema,
	}
end

function Schema.arrayOf(schema: any, options: any?): Schema
	options = options or {}
	return {
		kind = "array",
		schema = schema,
		maxItems = ceilingFrom(options.maxItems, DEFAULT_ARRAY_MAX_ITEMS),
	}
end

function Schema.object(shape: { [any]: any }?, options: any?): Schema
	options = options or {}
	return {
		kind = "object",
		shape = shape or {},
		allowExtra = options.allowExtra == true,
	}
end

function Schema.vector3(options: any?): Schema
	options = options or {}
	return {
		kind = "vector3",
		unitish = options.unitish == true,
		minMagnitude = options.minMagnitude,
		maxMagnitude = options.maxMagnitude,
	}
end

function Schema.custom(name: string?, validator: (any) -> (any, any?, any?)): Schema
	if type(validator) ~= "function" then
		error("Schema.custom expects a validator function", 2)
	end
	return {
		kind = "custom",
		name = name or "custom",
		validator = validator,
	}
end

Schema.validate = SchemaValidation.validate
Schema.describe = SchemaValidation.describe

return Schema
