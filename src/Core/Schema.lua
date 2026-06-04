--!strict

export type ValidationResult = {
	ok: boolean,
	reason: string?,
	value: any?,
	path: string?,
}

export type Schema = {
	kind: string,
	[string]: any,
}

local Schema: any = {}

local function result(ok: boolean, reason: string?, value: any?, path: string?): ValidationResult
	return {
		ok = ok == true,
		reason = reason,
		value = value,
		path = path,
	}
end

local function fail(path: string?, reason: string): ValidationResult
	if path and path ~= "" then
		return result(false, path .. ": " .. reason, nil, path)
	end
	return result(false, reason, nil, path)
end

local function childPath(path: string?, key: any): string
	if not path or path == "" then
		return tostring(key)
	end
	return path .. "." .. tostring(key)
end

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
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

local function isVector3(value: any): boolean
	local vector3Type = "Vector" .. "3"
	if typeof and typeof(value) == vector3Type then
		return true
	end
	return type(value) == "table" and isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z)
end

local function vectorMagnitude(value: any): number
	if value.Magnitude ~= nil then
		return value.Magnitude
	end
	return math.sqrt(value.X * value.X + value.Y * value.Y + value.Z * value.Z)
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
		maxLength = options.maxLength,
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

function Schema.oneOf(values: {any}): Schema
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

function Schema.arrayOf(schema: any): Schema
	return {
		kind = "array",
		schema = schema,
	}
end

function Schema.object(shape: {[any]: any}?, options: any?): Schema
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

local validators: {[string]: (Schema, any, string?) -> ValidationResult} = {}

function validators.any(schema: Schema, value: any, path: string?): ValidationResult
	return result(true, nil, value, path)
end

function validators.boolean(schema: Schema, value: any, path: string?): ValidationResult
	if type(value) ~= "boolean" then
		return fail(path, "expected boolean")
	end
	return result(true, nil, value, path)
end

function validators.number(schema: Schema, value: any, path: string?): ValidationResult
	if not isFiniteNumber(value) then
		return fail(path, "expected finite number")
	end
	if schema.min ~= nil and value < schema.min then
		return fail(path, "expected number >= " .. tostring(schema.min))
	end
	if schema.max ~= nil and value > schema.max then
		return fail(path, "expected number <= " .. tostring(schema.max))
	end
	return result(true, nil, value, path)
end

function validators.integer(schema: Schema, value: any, path: string?): ValidationResult
	if not isFiniteNumber(value) or value % 1 ~= 0 then
		return fail(path, "expected integer")
	end
	if schema.min ~= nil and value < schema.min then
		return fail(path, "expected integer >= " .. tostring(schema.min))
	end
	if schema.max ~= nil and value > schema.max then
		return fail(path, "expected integer <= " .. tostring(schema.max))
	end
	return result(true, nil, value, path)
end

function validators.string(schema: Schema, value: any, path: string?): ValidationResult
	if type(value) ~= "string" then
		return fail(path, "expected string")
	end
	local text = value or ""
	if schema.minLength ~= nil and #text < schema.minLength then
		return fail(path, "expected string length >= " .. tostring(schema.minLength))
	end
	if schema.maxLength ~= nil and #text > schema.maxLength then
		return fail(path, "expected string length <= " .. tostring(schema.maxLength))
	end
	if schema.pattern ~= nil and not string.match(text, schema.pattern) then
		return fail(path, "expected " .. (schema.description or "matching string"))
	end
	return result(true, nil, text, path)
end

function validators.oneOf(schema: Schema, value: any, path: string?): ValidationResult
	if not schema.allowed[value] then
		return fail(path, "expected one of allowed values")
	end
	return result(true, nil, value, path)
end

function validators.literal(schema: Schema, value: any, path: string?): ValidationResult
	if value ~= schema.expected then
		return fail(path, "expected literal " .. tostring(schema.expected))
	end
	return result(true, nil, value, path)
end

function validators.optional(schema: Schema, value: any, path: string?): ValidationResult
	if value == nil then
		return result(true, nil, nil, path)
	end
	return Schema.validate(schema.schema, value, path)
end

function validators.array(schema: Schema, value: any, path: string?): ValidationResult
	if not isArray(value) then
		return fail(path, "expected array")
	end

	for index, child in ipairs(value) do
		local childResult = Schema.validate(schema.schema, child, childPath(path, index))
		if not childResult.ok then
			return childResult
		end
	end

	return result(true, nil, value, path)
end

function validators.object(schema: Schema, value: any, path: string?): ValidationResult
	if type(value) ~= "table" then
		return fail(path, "expected object")
	end

	for key, childSchema in pairs(schema.shape) do
		local childResult = Schema.validate(childSchema, value[key], childPath(path, key))
		if not childResult.ok then
			return childResult
		end
	end

	if not schema.allowExtra then
		for key in pairs(value) do
			if schema.shape[key] == nil then
				return fail(childPath(path, key), "unexpected field")
			end
		end
	end

	return result(true, nil, value, path)
end

function validators.vector3(schema: Schema, value: any, path: string?): ValidationResult
	if not isVector3(value) then
		return fail(path, "expected Vector3-like value")
	end

	if schema.unitish or schema.minMagnitude ~= nil or schema.maxMagnitude ~= nil then
		local magnitude = vectorMagnitude(value)
		if not isFiniteNumber(magnitude) then
			return fail(path, "expected finite vector magnitude")
		end
		if schema.unitish and (magnitude < 0.001 or magnitude > 1.25) then
			return fail(path, "expected unit-ish vector")
		end
		if schema.minMagnitude ~= nil and magnitude < schema.minMagnitude then
			return fail(path, "expected vector magnitude >= " .. tostring(schema.minMagnitude))
		end
		if schema.maxMagnitude ~= nil and magnitude > schema.maxMagnitude then
			return fail(path, "expected vector magnitude <= " .. tostring(schema.maxMagnitude))
		end
	end

	return result(true, nil, value, path)
end

function validators.custom(schema: Schema, value: any, path: string?): ValidationResult
	local ok, acceptedOrReason, normalized = pcall(schema.validator, value)
	if not ok then
		return fail(path, tostring(acceptedOrReason))
	end
	if acceptedOrReason ~= true then
		return fail(path, tostring(acceptedOrReason or ("failed " .. schema.name .. " validation")))
	end
	return result(true, nil, normalized ~= nil and normalized or value, path)
end

function Schema.validate(schema: any, value: any, path: string?): ValidationResult
	if type(schema) == "function" then
		schema = Schema.custom("function", schema)
	end
	if type(schema) ~= "table" or not schema.kind then
		error("Schema.validate expects a schema", 2)
	end

	local validator = validators[schema.kind]
	if not validator then
		error("Unknown schema kind: " .. tostring(schema.kind), 2)
	end

	return validator(schema, value, path or "value")
end

return Schema
