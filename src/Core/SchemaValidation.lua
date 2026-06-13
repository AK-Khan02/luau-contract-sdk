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

local SchemaValidation = {}

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
	return math.sqrt(value.X * value.X + value.Y * value.Y + value.Z * value.Z)
end

local function copyList(values: { any }): { any }
	local copy = {}
	for index, value in ipairs(values) do
		copy[index] = value
	end
	return copy
end

local function copySerializable(value: any): any
	if type(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, child in pairs(value) do
		if type(child) ~= "function" then
			copy[key] = copySerializable(child)
		end
	end
	return copy
end

local validators: { [string]: (Schema, any, string?) -> ValidationResult } = {}

function validators.any(_schema: Schema, value: any, path: string?): ValidationResult
	return result(true, nil, value, path)
end

function validators.boolean(_schema: Schema, value: any, path: string?): ValidationResult
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
	return SchemaValidation.validate(schema.schema, value, path)
end

function validators.array(schema: Schema, value: any, path: string?): ValidationResult
	if not isArray(value) then
		return fail(path, "expected array")
	end

	if schema.maxItems ~= nil and #value > schema.maxItems then
		return fail(path, "expected array length <= " .. tostring(schema.maxItems))
	end

	for index, child in ipairs(value) do
		local childResult = SchemaValidation.validate(schema.schema, child, childPath(path, index))
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

	-- Read shape fields with rawget so a metatable's __index cannot spoof a
	-- field that the raw table does not contain. The extra-key sweep below also
	-- iterates the raw table (pairs), so both halves agree on what is present.
	for key, childSchema in pairs(schema.shape) do
		local childResult = SchemaValidation.validate(childSchema, rawget(value, key), childPath(path, key))
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

	if type(value) == "table" then
		return result(true, nil, { X = value.X, Y = value.Y, Z = value.Z }, path)
	end

	return result(true, nil, value, path)
end

function validators.custom(schema: Schema, value: any, path: string?): ValidationResult
	local ok, acceptedOrReason, _reason, normalized = pcall(schema.validator, value)
	if not ok then
		return fail(path, tostring(acceptedOrReason))
	end
	if acceptedOrReason ~= true then
		return fail(path, tostring(acceptedOrReason or ("failed " .. schema.name .. " validation")))
	end
	return result(true, nil, normalized ~= nil and normalized or value, path)
end

function SchemaValidation.validate(schema: any, value: any, path: string?): ValidationResult
	if type(schema) == "function" then
		schema = {
			kind = "custom",
			name = "function",
			validator = schema,
		}
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

function SchemaValidation.describe(schema: any): any
	if type(schema) == "function" then
		return {
			kind = "custom",
			name = "function",
		}
	end
	if type(schema) ~= "table" or not schema.kind then
		error("Schema.describe expects a schema", 2)
	end

	if schema.kind == "any" or schema.kind == "boolean" then
		return {
			kind = schema.kind,
		}
	end
	if schema.kind == "number" or schema.kind == "integer" then
		return {
			kind = schema.kind,
			min = schema.min,
			max = schema.max,
		}
	end
	if schema.kind == "string" then
		return {
			kind = "string",
			minLength = schema.minLength,
			maxLength = schema.maxLength,
			pattern = schema.pattern,
			description = schema.description,
		}
	end
	if schema.kind == "oneOf" then
		return {
			kind = "oneOf",
			values = copyList(schema.values or {}),
		}
	end
	if schema.kind == "literal" then
		return {
			kind = "literal",
			expected = copySerializable(schema.expected),
		}
	end
	if schema.kind == "optional" then
		return {
			kind = "optional",
			schema = SchemaValidation.describe(schema.schema),
		}
	end
	if schema.kind == "array" then
		return {
			kind = "array",
			schema = SchemaValidation.describe(schema.schema),
			maxItems = schema.maxItems,
		}
	end
	if schema.kind == "object" then
		local shape = {}
		for key, childSchema in pairs(schema.shape or {}) do
			shape[key] = SchemaValidation.describe(childSchema)
		end
		return {
			kind = "object",
			shape = shape,
			allowExtra = schema.allowExtra == true,
		}
	end
	if schema.kind == "vector3" then
		return {
			kind = "vector3",
			unitish = schema.unitish == true,
			minMagnitude = schema.minMagnitude,
			maxMagnitude = schema.maxMagnitude,
		}
	end
	if schema.kind == "custom" then
		return {
			kind = "custom",
			name = schema.name,
		}
	end

	error("Unknown schema kind: " .. tostring(schema.kind), 2)
end

return SchemaValidation
