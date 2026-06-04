--!strict

local Schema = require("./Schema")

export type Description = {
	name: string,
	ownedTags: {string},
	ownedFolders: {string},
	mayRead: {string},
	mayWrite: {string},
	mustNeverTouch: {string},
	remotes: {[string]: any},
	postconditions: {string},
	lifecycles: {[string]: any},
}

local System: any = {}
System.__index = System

local function copyList(values: {any}): {any}
	local copy = {}
	for index, value in ipairs(values) do
		copy[index] = value
	end
	return copy
end

local function copyMap(values: any): any
	local copy = {}
	for key, value in pairs(values) do
		copy[key] = value
	end
	return copy
end

local function appendUnique(values: {string}, value: string)
	for _, existing in ipairs(values) do
		if existing == value then
			return
		end
	end
	table.insert(values, value)
end

local function assertName(kind: string, value: any)
	if type(value) ~= "string" or value == "" then
		error(kind .. " must be a non-empty string", 3)
	end
end

local function matchesBoundary(target: any, boundary: string): boolean
	if target == boundary then
		return true
	end
	return type(target) == "string" and string.sub(target, 1, #boundary + 1) == boundary .. "."
end

local function recordViolation(diagnostics: any, fields: any): any
	if diagnostics and diagnostics.record then
		local target: any = diagnostics
		return target:record(fields)
	end
	return fields
end

function System.new(name: string): any
	assertName("System name", name)

	return setmetatable({
		_name = name,
		_ownedTags = {},
		_ownedFolders = {},
		_mayRead = {},
		_mayWrite = {},
		_mustNeverTouch = {},
		_remotes = {},
		_postconditions = {},
		_lifecycles = {},
	}, System)
end

function System.name(self: any): string
	return self._name
end

function System.ownsTag(self: any, tagName: string): any
	assertName("Owned tag", tagName)
	appendUnique(self._ownedTags, tagName)
	return self
end

function System.ownsFolder(self: any, folderPath: string): any
	assertName("Owned folder", folderPath)
	appendUnique(self._ownedFolders, folderPath)
	return self
end

function System.mayRead(self: any, path: string): any
	assertName("Readable path", path)
	appendUnique(self._mayRead, path)
	return self
end

function System.mayWrite(self: any, path: string): any
	assertName("Writable path", path)
	appendUnique(self._mayWrite, path)
	return self
end

function System.mustNeverTouch(self: any, path: string): any
	assertName("Forbidden path", path)
	appendUnique(self._mustNeverTouch, path)
	return self
end

function System.remote(self: any, remoteName: string, schema: any, options: any?): any
	assertName("Remote name", remoteName)
	self._remotes[remoteName] = {
		schema = schema,
		options = options or {},
	}
	return self
end

function System.lifecycle(self: any, name: string, lifecycle: any): any
	assertName("Lifecycle name", name)
	self._lifecycles[name] = lifecycle
	return self
end

function System.postcondition(self: any, name: string, check: (any) -> any): any
	assertName("Postcondition name", name)
	if type(check) ~= "function" then
		error("Postcondition check must be a function", 2)
	end

	table.insert(self._postconditions, {
		name = name,
		check = check,
	})
	return self
end

function System.remoteOptions(self: any, remoteName: string): any?
	local remote = self._remotes[remoteName]
	if not remote then
		return nil
	end
	return copyMap(remote.options)
end

function System.validateRemote(self: any, remoteName: string, payload: any, diagnostics: any?, context: any?): any
	local remote = self._remotes[remoteName]
	if not remote then
		local message = "unknown remote contract: " .. tostring(remoteName)
		recordViolation(diagnostics, {
			level = "error",
			category = "remote",
			system = self._name,
			name = "UnknownRemote",
			message = message,
			context = context or {
				remote = remoteName,
			},
		})
		return {
			ok = false,
			reason = message,
		}
	end

	local validation = Schema.validate(remote.schema, payload, "payload")
	if not validation.ok then
		recordViolation(diagnostics, {
			level = "error",
			category = "remote",
			system = self._name,
			name = "RemotePayloadInvalid",
			message = validation.reason,
			context = context or {
				remote = remoteName,
			},
		})
	end
	return validation
end

function System.checkTouch(self: any, actionName: string, targetPath: string, diagnostics: any?, context: any?): any
	for _, boundary in ipairs(self._mustNeverTouch) do
		if matchesBoundary(targetPath, boundary) then
			local name = "ForbiddenTouch"
			local message = self._name .. " must never touch " .. boundary
			recordViolation(diagnostics, {
				level = "error",
				category = "ownership",
				system = self._name,
				name = name,
				message = message,
				context = context or {
					action = actionName,
					target = targetPath,
					boundary = boundary,
				},
			})
			return {
				ok = false,
				name = name,
				reason = message,
			}
		end
	end

	return {
		ok = true,
	}
end

function System.checkPostcondition(self: any, name: string, context: any?, diagnostics: any?): any
	for _, postcondition in ipairs(self._postconditions) do
		if postcondition.name == name then
			local ok, acceptedOrReason = pcall(postcondition.check, context or {})
			if ok and acceptedOrReason == true then
				return {
					ok = true,
					name = name,
				}
			end

			local reason = ok and acceptedOrReason or ("postcondition errored: " .. tostring(acceptedOrReason))
			local message = "Postcondition failed: " .. name
			if reason ~= nil and reason ~= false then
				message ..= " (" .. tostring(reason) .. ")"
			end

			recordViolation(diagnostics, {
				level = "error",
				category = "postcondition",
				system = self._name,
				name = name,
				message = message,
				context = context or {},
			})

			return {
				ok = false,
				name = name,
				reason = reason,
				message = message,
			}
		end
	end

	return {
		ok = false,
		name = name,
		reason = "unknown postcondition",
	}
end

function System.checkPostconditions(self: any, context: any?, diagnostics: any?): any
	local failures = {}

	for _, postcondition in ipairs(self._postconditions) do
		local result = self:checkPostcondition(postcondition.name, context, diagnostics)
		if not result.ok then
			table.insert(failures, result)
		end
	end

	return {
		ok = #failures == 0,
		failures = failures,
	}
end

function System.describe(self: any): Description
	local remotes = {}
	for name, remote in pairs(self._remotes) do
		remotes[name] = {
			schema = remote.schema,
			options = copyMap(remote.options),
		}
	end

	local postconditions = {}
	for _, postcondition in ipairs(self._postconditions) do
		table.insert(postconditions, postcondition.name)
	end

	return {
		name = self._name,
		ownedTags = copyList(self._ownedTags),
		ownedFolders = copyList(self._ownedFolders),
		mayRead = copyList(self._mayRead),
		mayWrite = copyList(self._mayWrite),
		mustNeverTouch = copyList(self._mustNeverTouch),
		remotes = remotes,
		postconditions = postconditions,
		lifecycles = copyMap(self._lifecycles),
	}
end

return System
