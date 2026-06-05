--!strict

local JsonEncode = {}

local ESCAPES: {[string]: string} = {
	["\\"] = "\\\\",
	["\""] = "\\\"",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function escapeControl(character: string): string
	return ESCAPES[character] or ("\\u%04x"):format(string.byte(character))
end

local function encodeString(value: string): string
	return "\"" .. string.gsub(value, "[%z\1-\31\\\"]", escapeControl) .. "\""
end

local function isArray(value: any): boolean
	if type(value) ~= "table" then
		return false
	end

	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false
		end
		count += 1
	end
	return count == #value
end

local function sortedObjectEntries(value: {[any]: any}): {any}
	local entries = {}
	for key, child in pairs(value) do
		if child ~= nil then
			table.insert(entries, {
				key = key,
				name = tostring(key),
			})
		end
	end
	table.sort(entries, function(left: any, right: any)
		return left.name < right.name
	end)
	return entries
end

local function encodeValue(value: any, seen: {[any]: boolean}): string
	local valueType = type(value)

	if value == nil then
		return "null"
	end
	if valueType == "string" then
		return encodeString(value)
	end
	if valueType == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			error("cannot encode non-finite number", 3)
		end
		return tostring(value)
	end
	if valueType == "boolean" then
		return value and "true" or "false"
	end
	if valueType ~= "table" then
		error("cannot encode " .. valueType .. " as JSON", 3)
	end

	if seen[value] then
		error("cannot encode cyclic table as JSON", 3)
	end
	seen[value] = true

	local encoded = {}
	if isArray(value) then
		for index = 1, #value do
			encoded[index] = encodeValue(value[index], seen)
		end
		seen[value] = nil
		return "[" .. table.concat(encoded, ",") .. "]"
	end

	for _, entry in ipairs(sortedObjectEntries(value)) do
		table.insert(encoded, encodeString(entry.name) .. ":" .. encodeValue(value[entry.key], seen))
	end
	seen[value] = nil
	return "{" .. table.concat(encoded, ",") .. "}"
end

function JsonEncode.encode(value: any): string
	return encodeValue(value, {})
end

return JsonEncode
