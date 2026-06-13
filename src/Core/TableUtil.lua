--!strict

local TableUtil = {}

function TableUtil.copyList(values: { any }?): { any }
	local copy = {}
	for index, value in ipairs(values or {}) do
		copy[index] = value
	end
	return copy
end

function TableUtil.copyMap(values: any): any
	if type(values) ~= "table" then
		return values
	end

	local copy = {}
	for key, value in pairs(values) do
		copy[key] = value
	end
	return copy
end

local function deepCopyValue(value: any, seen: any): any
	if type(value) ~= "table" then
		return value
	end
	if seen[value] ~= nil then
		return seen[value]
	end

	local copy = {}
	seen[value] = copy
	for key, child in pairs(value) do
		copy[deepCopyValue(key, seen)] = deepCopyValue(child, seen)
	end
	return copy
end

function TableUtil.deepCopy(value: any): any
	return deepCopyValue(value, {})
end

function TableUtil.appendUnique(values: { string }, value: string)
	for _, existing in ipairs(values) do
		if existing == value then
			return
		end
	end
	table.insert(values, value)
end

function TableUtil.sortedStringKeys(values: any): { string }
	local keys = {}
	for key in pairs(values or {}) do
		if type(key) == "string" then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	return keys
end

return TableUtil
