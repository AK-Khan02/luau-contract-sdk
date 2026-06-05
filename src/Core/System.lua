--!strict

local ActionScope = require("./ActionScope")
local Schema = require("./Schema")

export type ActionDescription = {
	name: string,
	input: any?,
	output: any?,
	context: any?,
	reads: {string},
	writes: {string},
	touches: {string},
	creates: {string},
	destroys: {string},
	forbids: {string},
	preconditions: {string},
	postconditions: {string},
	lifecycle: any,
	remote: any?,
	policy: any,
	tags: {string},
}

export type Description = {
	name: string,
	ownedTags: {string},
	ownedFolders: {string},
	mayRead: {string},
	mayWrite: {string},
	mustNeverTouch: {string},
	actions: {[string]: ActionDescription},
	remotes: {[string]: any},
	preconditions: {string},
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
	if type(values) ~= "table" then
		return values
	end

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

local function normalizeStringList(kind: string, values: any?): {string}
	if values == nil then
		return {}
	end
	if type(values) == "string" then
		assertName(kind, values)
		return { values }
	end
	if type(values) ~= "table" then
		error(kind .. " must be a string or array of strings", 3)
	end

	local normalized = {}
	for _, value in ipairs(values) do
		assertName(kind, value)
		appendUnique(normalized, value :: string)
	end
	return normalized
end

local function normalizeStringMap(kind: string, values: any?): {[string]: string}
	if values == nil then
		return {}
	end
	if type(values) ~= "table" then
		error(kind .. " must be a map of strings", 3)
	end

	local normalized = {}
	for key, value in pairs(values) do
		assertName(kind .. " key", key)
		assertName(kind .. " value", value)
		normalized[key :: string] = value :: string
	end
	return normalized
end

local function normalizePolicy(definition: any): any
	if definition == nil then
		return {}
	end
	if type(definition) ~= "table" then
		error("Action policy must be a table", 3)
	end
	return copyMap(definition)
end

local function normalizeLifecyclePolicy(definition: any): any
	definition = definition or {}
	if type(definition) ~= "table" then
		error("Action lifecycle must be a table", 3)
	end

	return {
		requires = normalizeStringMap("Action lifecycle requirement", definition.requires or definition.requiresState),
		emits = normalizeStringMap("Action lifecycle event", definition.emits),
	}
end

local function normalizeRemoteBinding(actionName: string, remote: any): any?
	if remote == nil then
		return nil
	end
	if type(remote) == "string" then
		assertName("Action remote", remote)
		return {
			name = remote,
			action = actionName,
		}
	end
	if type(remote) ~= "table" then
		error("Action remote must be a string or table", 3)
	end

	local remoteName = remote.name or remote.remoteName
	assertName("Action remote", remoteName)

	local normalized = copyMap(remote)
	normalized.name = remoteName
	normalized.action = actionName
	return normalized
end

local function normalizeCheckReferences(kind: string, references: any?): any
	if references == nil then
		return {}
	end
	if references == "all" then
		return "all"
	end
	if type(references) == "string" then
		assertName(kind, references)
		return { references }
	end
	return normalizeStringList(kind, references)
end

local function checkNames(references: any, fallback: {any}?): {string}
	local names = {}
	if references == "all" then
		for _, check in ipairs(fallback or {}) do
			table.insert(names, check.name)
		end
		return names
	end

	for _, name in ipairs(references or {}) do
		table.insert(names, name :: string)
	end
	return names
end

local function matchesBoundary(target: any, boundary: string): boolean
	if target == boundary then
		return true
	end
	return type(target) == "string" and string.sub(target, 1, #boundary + 1) == boundary .. "."
end

local function matchesAnyBoundary(target: string, boundaries: {string}): (boolean, string?)
	for _, boundary in ipairs(boundaries) do
		if matchesBoundary(target, boundary) then
			return true, boundary
		end
	end
	return false, nil
end

local function recordViolation(diagnostics: any, fields: any): any
	if diagnostics and diagnostics.record then
		local target: any = diagnostics
		return target:record(fields)
	end
	return fields
end

local function actionContext(options: any, systemName: string, actionName: string): any
	local source = options.context or {}
	local context = copyMap(source)

	context.action = context.action or actionName
	context.system = context.system or systemName

	if options.actor ~= nil then
		context.actor = options.actor
		context.player = context.player or options.actor
	end
	if options.payload ~= nil then
		context.payload = options.payload
		context.input = options.payload
	end
	if options.remote ~= nil then
		context.remote = options.remote
	end

	return context
end

local function actionInput(options: any, context: any): any
	if options.payload ~= nil then
		return options.payload
	end
	return context.input or context.payload
end

local function actionStates(options: any): any
	return copyMap(options.states or {})
end

local function buildAction(actionName: string, definition: any): any
	if type(definition) ~= "table" then
		error("Action definition must be a table", 3)
	end

	return {
		name = actionName,
		input = definition.input or definition.schema,
		output = definition.output or definition.result,
		context = definition.context,
		reads = normalizeStringList("Action read path", definition.reads or definition.mayRead),
		writes = normalizeStringList("Action write path", definition.writes or definition.mayWrite),
		touches = normalizeStringList("Action touch path", definition.touches),
		creates = normalizeStringList("Action create path", definition.creates),
		destroys = normalizeStringList("Action destroy path", definition.destroys),
		forbids = normalizeStringList("Action forbidden path", definition.forbids or definition.mustNeverTouch),
		preconditions = normalizeCheckReferences("Action precondition", definition.preconditions),
		postconditions = normalizeCheckReferences("Action postcondition", definition.postconditions),
		lifecycle = normalizeLifecyclePolicy(definition.lifecycle or {
			requires = definition.requiresState,
			emits = definition.emits,
		}),
		remote = normalizeRemoteBinding(actionName, definition.remote),
		policy = normalizePolicy(definition.policy or definition.policies),
		tags = normalizeStringList("Action tag", definition.tags),
	}
end

local function describeAction(action: any, preconditionFallback: {any}, postconditionFallback: {any}): ActionDescription
	return {
		name = action.name,
		input = action.input,
		output = action.output,
		context = action.context,
		reads = copyList(action.reads),
		writes = copyList(action.writes),
		touches = copyList(action.touches),
		creates = copyList(action.creates),
		destroys = copyList(action.destroys),
		forbids = copyList(action.forbids),
		preconditions = checkNames(action.preconditions, preconditionFallback),
		postconditions = checkNames(action.postconditions, postconditionFallback),
		lifecycle = copyMap(action.lifecycle),
		remote = copyMap(action.remote),
		policy = copyMap(action.policy),
		tags = copyList(action.tags),
	}
end

local function evaluateCheck(check: any, context: any): (boolean, any?)
	local ok, acceptedOrReason = pcall(check, context or {})
	if not ok then
		return false, acceptedOrReason
	end
	if acceptedOrReason == true then
		return true, nil
	end
	return false, acceptedOrReason
end

local function checkResult(ok: boolean, name: string, reason: any?, message: string?): any
	if ok then
		return {
			ok = true,
			name = name,
		}
	end

	return {
		ok = false,
		name = name,
		reason = reason,
		message = message,
	}
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
		_actions = {},
		_remotes = {},
		_preconditions = {},
		_preconditionChecks = {},
		_postconditions = {},
		_postconditionChecks = {},
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

function System.action(self: any, actionName: string, definition: any): any
	assertName("Action name", actionName)
	local action = buildAction(actionName, definition)
	self._actions[actionName] = action

	if action.remote ~= nil then
		local remote = copyMap(action.remote)
		local remoteName = remote.name
		remote.name = nil
		self._remotes[remoteName] = {
			schema = action.input or Schema.any(),
			options = remote,
		}
	end

	return self
end

function System.lifecycle(self: any, name: string, lifecycle: any): any
	assertName("Lifecycle name", name)
	self._lifecycles[name] = lifecycle
	return self
end

function System.precondition(self: any, name: string, check: (any) -> any): any
	assertName("Precondition name", name)
	if type(check) ~= "function" then
		error("Precondition check must be a function", 2)
	end

	if self._preconditionChecks[name] == nil then
		table.insert(self._preconditions, {
			name = name,
			check = check,
		})
	end
	self._preconditionChecks[name] = check
	return self
end

function System.postcondition(self: any, name: string, check: (any) -> any): any
	assertName("Postcondition name", name)
	if type(check) ~= "function" then
		error("Postcondition check must be a function", 2)
	end

	if self._postconditionChecks[name] == nil then
		table.insert(self._postconditions, {
			name = name,
			check = check,
		})
	end
	self._postconditionChecks[name] = check
	return self
end

function System.remoteOptions(self: any, remoteName: string): any?
	local remote = self._remotes[remoteName]
	if not remote then
		return nil
	end
	return copyMap(remote.options)
end

function System.actionOptions(self: any, actionName: string): any?
	local action = self._actions[actionName]
	if not action then
		return nil
	end
	return describeAction(action, self._preconditions, self._postconditions)
end

function System.hasAction(self: any, actionName: string): boolean
	return self._actions[actionName] ~= nil
end

function System.actionForRemote(self: any, remoteName: string): string?
	local remote = self._remotes[remoteName]
	if remote == nil then
		return nil
	end
	local options = remote.options
	if options == nil then
		return nil
	end
	return options.action :: string?
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

function System.validateActionInput(self: any, actionName: string, payload: any, diagnostics: any?, context: any?): any
	local action = self._actions[actionName]
	if not action then
		local message = "unknown action contract: " .. tostring(actionName)
		recordViolation(diagnostics, {
			level = "error",
			category = "action",
			system = self._name,
			name = "UnknownAction",
			message = message,
			context = context or {
				action = actionName,
			},
		})
		return {
			ok = false,
			reason = message,
		}
	end
	if action.input == nil then
		return {
			ok = true,
			value = payload,
		}
	end

	local validation = Schema.validate(action.input, payload, "payload")
	if not validation.ok then
		recordViolation(diagnostics, {
			level = "error",
			category = "action",
			system = self._name,
			name = "ActionInputInvalid",
			message = validation.reason,
			context = context or {
				action = actionName,
			},
		})
	end
	return validation
end

function System.validateActionOutput(self: any, actionName: string, value: any, diagnostics: any?, context: any?): any
	local action = self._actions[actionName]
	if not action then
		local message = "unknown action contract: " .. tostring(actionName)
		recordViolation(diagnostics, {
			level = "error",
			category = "action",
			system = self._name,
			name = "UnknownAction",
			message = message,
			context = context or {
				action = actionName,
			},
		})
		return {
			ok = false,
			reason = message,
		}
	end
	if action.output == nil then
		return {
			ok = true,
			value = value,
		}
	end

	local validation = Schema.validate(action.output, value, "result")
	if not validation.ok then
		recordViolation(diagnostics, {
			level = "error",
			category = "action",
			system = self._name,
			name = "ActionOutputInvalid",
			message = validation.reason,
			context = context or {
				action = actionName,
			},
		})
	end
	return validation
end

function System.validateActionContext(self: any, actionName: string, context: any, diagnostics: any?): any
	local action = self._actions[actionName]
	if not action then
		return {
			ok = false,
			reason = "unknown action contract: " .. tostring(actionName),
		}
	end
	if action.context == nil then
		return {
			ok = true,
			value = context,
		}
	end

	local validation = Schema.validate(action.context, context, "context")
	if not validation.ok then
		recordViolation(diagnostics, {
			level = "error",
			category = "action",
			system = self._name,
			name = "ActionContextInvalid",
			message = validation.reason,
			context = context or {
				action = actionName,
			},
		})
	end
	return validation
end

function System.checkForbiddenTouch(self: any, actionName: string?, targetPath: string, diagnostics: any?, context: any?): any
	assertName("Target path", targetPath)
	local action = actionName and self._actions[actionName]
	local forbidden = copyList(self._mustNeverTouch)
	if action then
		for _, path in ipairs(action.forbids) do
			appendUnique(forbidden, path)
		end
	end

	local matched, boundary = matchesAnyBoundary(targetPath, forbidden)
	if matched then
		local name = "ForbiddenTouch"
		local message = self._name .. " must never touch " .. tostring(boundary)
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

	return {
		ok = true,
	}
end

function System.checkPermission(self: any, actionName: string?, accessKind: string, targetPath: string, diagnostics: any?, context: any?): any
	assertName("Access kind", accessKind)
	assertName("Target path", targetPath)

	local forbidden = self:checkForbiddenTouch(actionName, targetPath, diagnostics, context)
	if not forbidden.ok then
		return forbidden
	end

	local action = actionName and self._actions[actionName]
	local systemBoundaries = accessKind == "read" and self._mayRead or self._mayWrite
	local actionBoundaries = {}
	if action then
		actionBoundaries = accessKind == "read" and action.reads or action.writes
	end

	local systemAllows = #systemBoundaries == 0 or matchesAnyBoundary(targetPath, systemBoundaries)
	local actionAllows = action == nil or #actionBoundaries == 0 or matchesAnyBoundary(targetPath, actionBoundaries)

	if systemAllows and actionAllows then
		return {
			ok = true,
		}
	end

	local name = accessKind == "read" and "ReadNotAllowed" or "WriteNotAllowed"
	local message = self._name .. " may not " .. accessKind .. " " .. targetPath
	recordViolation(diagnostics, {
		level = "error",
		category = "ownership",
		system = self._name,
		name = name,
		message = message,
		context = context or {
			action = actionName,
			target = targetPath,
			access = accessKind,
		},
	})

	return {
		ok = false,
		name = name,
		reason = message,
	}
end

function System.checkRead(self: any, actionName: string?, targetPath: string, diagnostics: any?, context: any?): any
	return self:checkPermission(actionName, "read", targetPath, diagnostics, context)
end

function System.checkWrite(self: any, actionName: string?, targetPath: string, diagnostics: any?, context: any?): any
	return self:checkPermission(actionName, "write", targetPath, diagnostics, context)
end

function System.checkEffect(self: any, actionName: string?, effect: any, diagnostics: any?, context: any?): any
	if type(effect) ~= "table" then
		error("Effect must be a table", 2)
	end

	local kind = effect.kind or effect.type
	local targetPath = effect.target or effect.path
	assertName("Effect kind", kind)
	assertName("Effect target", targetPath)

	if kind == "read" then
		return self:checkRead(actionName, targetPath, diagnostics, context)
	end
	if kind == "write" then
		return self:checkWrite(actionName, targetPath, diagnostics, context)
	end
	if kind == "create" or kind == "destroy" or kind == "touch" then
		local forbidden = self:checkForbiddenTouch(actionName, targetPath, diagnostics, context)
		if not forbidden.ok then
			return forbidden
		end

		local action = actionName and self._actions[actionName]
		local actionBoundaries = {}
		if action then
			if kind == "create" then
				actionBoundaries = #action.creates > 0 and action.creates or action.writes
			elseif kind == "destroy" then
				actionBoundaries = #action.destroys > 0 and action.destroys or action.writes
			else
				actionBoundaries = #action.touches > 0 and action.touches or action.writes
			end
		end

		local systemAllows = #self._mayWrite == 0 or matchesAnyBoundary(targetPath, self._mayWrite)
		local actionAllows = action == nil or #actionBoundaries == 0 or matchesAnyBoundary(targetPath, actionBoundaries)
		if systemAllows and actionAllows then
			return {
				ok = true,
			}
		end

		local names = {
			create = "CreateNotAllowed",
			destroy = "DestroyNotAllowed",
			touch = "TouchNotAllowed",
		}
		local name = names[kind] or "EffectNotAllowed"
		local message = self._name .. " may not " .. kind .. " " .. targetPath
		recordViolation(diagnostics, {
			level = "error",
			category = "ownership",
			system = self._name,
			name = name,
			message = message,
			context = context or {
				action = actionName,
				target = targetPath,
				effect = kind,
			},
		})

		return {
			ok = false,
			name = name,
			reason = message,
		}
	end

	local name = "UnknownEffectKind"
	local message = "unknown action effect kind: " .. tostring(kind)
	recordViolation(diagnostics, {
		level = "error",
		category = "action",
		system = self._name,
		name = name,
		message = message,
		context = context or {
			action = actionName,
			kind = kind,
			target = targetPath,
		},
	})

	return {
		ok = false,
		name = name,
		reason = message,
	}
end

function System.checkTouch(self: any, actionName: string, targetPath: string, diagnostics: any?, context: any?): any
	return self:checkForbiddenTouch(actionName, targetPath, diagnostics, context)
end

function System.checkPrecondition(self: any, name: string, context: any?, diagnostics: any?): any
	assertName("Precondition name", name)
	local check = self._preconditionChecks[name]
	if check == nil then
		return {
			ok = false,
			name = name,
			reason = "unknown precondition",
		}
	end

	local accepted, reason = evaluateCheck(check, context or {})
	if accepted then
		return checkResult(true, name, nil, nil)
	end

	local message = "Precondition failed: " .. name
	if reason ~= nil and reason ~= false then
		message ..= " (" .. tostring(reason) .. ")"
	end

	recordViolation(diagnostics, {
		level = "error",
		category = "precondition",
		system = self._name,
		name = name,
		message = message,
		context = context or {},
	})

	return checkResult(false, name, reason, message)
end

function System.checkPreconditions(self: any, context: any?, diagnostics: any?, references: any?): any
	local failures = {}
	local names = references == nil and checkNames("all", self._preconditions) or checkNames(references, self._preconditions)

	for _, name in ipairs(names) do
		local result = self:checkPrecondition(name, context, diagnostics)
		if not result.ok then
			table.insert(failures, result)
		end
	end

	return {
		ok = #failures == 0,
		failures = failures,
	}
end

function System.checkPostcondition(self: any, name: string, context: any?, diagnostics: any?): any
	assertName("Postcondition name", name)
	local check = self._postconditionChecks[name]
	if check == nil then
		return {
			ok = false,
			name = name,
			reason = "unknown postcondition",
		}
	end

	local accepted, reason = evaluateCheck(check, context or {})
	if accepted then
		return checkResult(true, name, nil, nil)
	end

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

	return checkResult(false, name, reason, message)
end

function System.checkPostconditions(self: any, context: any?, diagnostics: any?, references: any?): any
	local failures = {}
	local names = references == nil and checkNames("all", self._postconditions) or checkNames(references, self._postconditions)

	for _, name in ipairs(names) do
		local result = self:checkPostcondition(name, context, diagnostics)
		if not result.ok then
			table.insert(failures, result)
		end
	end

	return {
		ok = #failures == 0,
		failures = failures,
	}
end

function System.checkActionPreconditions(self: any, actionName: string, context: any?, diagnostics: any?): any
	local action = self._actions[actionName]
	if not action then
		return {
			ok = false,
			failures = {
				{
					ok = false,
					name = "UnknownAction",
					reason = "unknown action contract: " .. tostring(actionName),
				},
			},
		}
	end
	return self:checkPreconditions(context, diagnostics, action.preconditions)
end

function System.checkActionPostconditions(self: any, actionName: string, context: any?, diagnostics: any?): any
	local action = self._actions[actionName]
	if not action then
		return {
			ok = false,
			failures = {
				{
					ok = false,
					name = "UnknownAction",
					reason = "unknown action contract: " .. tostring(actionName),
				},
			},
		}
	end
	return self:checkPostconditions(context, diagnostics, action.postconditions)
end

function System.checkActionLifecycle(self: any, actionName: string, states: any, diagnostics: any?, context: any?): any
	local action = self._actions[actionName]
	if not action then
		return {
			ok = false,
			failures = {
				{
					ok = false,
					name = "UnknownAction",
					reason = "unknown action contract: " .. tostring(actionName),
				},
			},
		}
	end

	local failures = {}
	for lifecycleName, requiredState in pairs(action.lifecycle.requires) do
		local currentState = states and states[lifecycleName]
		if currentState ~= requiredState then
			local name = "ActionLifecycleStateInvalid"
			local message = self._name .. "." .. actionName .. " requires " .. lifecycleName .. " to be " .. requiredState
			recordViolation(diagnostics, {
				level = "error",
				category = "lifecycle",
				system = self._name,
				name = name,
				message = message,
				context = context or {
					action = actionName,
					lifecycle = lifecycleName,
					expected = requiredState,
					actual = currentState,
				},
			})
			table.insert(failures, {
				ok = false,
				name = name,
				reason = message,
			})
		end
	end

	return {
		ok = #failures == 0,
		failures = failures,
	}
end

function System.reduceActionLifecycle(self: any, actionName: string, states: any, diagnostics: any?, context: any?): any
	local action = self._actions[actionName]
	local nextStates = copyMap(states or {})
	local transitions = {}
	local failures = {}

	if not action then
		return {
			ok = false,
			states = nextStates,
			transitions = transitions,
			failures = {
				{
					ok = false,
					name = "UnknownAction",
					reason = "unknown action contract: " .. tostring(actionName),
				},
			},
		}
	end

	for lifecycleName, eventName in pairs(action.lifecycle.emits) do
		local lifecycle = self._lifecycles[lifecycleName]
		local currentState = nextStates[lifecycleName]
		if lifecycle == nil then
			local name = "ActionLifecycleUnknown"
			local message = "unknown lifecycle contract: " .. tostring(lifecycleName)
			recordViolation(diagnostics, {
				level = "error",
				category = "lifecycle",
				system = self._name,
				name = name,
				message = message,
				context = context or {
					action = actionName,
					lifecycle = lifecycleName,
					event = eventName,
				},
			})
			table.insert(failures, {
				ok = false,
				name = name,
				reason = message,
			})
		elseif currentState == nil then
			local name = "ActionLifecycleStateMissing"
			local message = self._name .. "." .. actionName .. " needs current " .. lifecycleName .. " state"
			recordViolation(diagnostics, {
				level = "error",
				category = "lifecycle",
				system = self._name,
				name = name,
				message = message,
				context = context or {
					action = actionName,
					lifecycle = lifecycleName,
					event = eventName,
				},
			})
			table.insert(failures, {
				ok = false,
				name = name,
				reason = message,
			})
		else
			local nextState, didTransition = lifecycle:reduce(currentState, eventName)
			if didTransition then
				nextStates[lifecycleName] = nextState
				table.insert(transitions, {
					lifecycle = lifecycleName,
					event = eventName,
					from = currentState,
					to = nextState,
				})
			else
				local name = "ActionLifecycleTransitionInvalid"
				local message = self._name .. "." .. actionName .. " cannot emit " .. eventName .. " from " .. tostring(currentState)
				recordViolation(diagnostics, {
					level = "error",
					category = "lifecycle",
					system = self._name,
					name = name,
					message = message,
					context = context or {
						action = actionName,
						lifecycle = lifecycleName,
						event = eventName,
						state = currentState,
					},
				})
				table.insert(failures, {
					ok = false,
					name = name,
					reason = message,
				})
			end
		end
	end

	return {
		ok = #failures == 0,
		states = nextStates,
		transitions = transitions,
		failures = failures,
	}
end

function System.checkActionPolicy(self: any, actionName: string, context: any?, diagnostics: any?): any
	local action = self._actions[actionName]
	if not action then
		return {
			ok = false,
			name = "UnknownAction",
			reason = "unknown action contract: " .. tostring(actionName),
		}
	end

	local policy = action.policy or {}
	local actorPolicy = policy.actor or policy.authorize
	local actorRequired = policy.actorRequired == true or actorPolicy == "required"
	if actorRequired and (context == nil or context.actor == nil) then
		local name = "ActionActorRejected"
		local message = self._name .. "." .. actionName .. " requires an actor"
		recordViolation(diagnostics, {
			level = "error",
			category = "action",
			system = self._name,
			name = name,
			message = message,
			context = context or {
				action = actionName,
			},
		})
		return {
			ok = false,
			name = name,
			reason = message,
		}
	end

	if type(actorPolicy) ~= "function" then
		return {
			ok = true,
		}
	end

	local ok, acceptedOrReason = pcall(actorPolicy, context and context.actor, context or {})
	if ok and acceptedOrReason == true then
		return {
			ok = true,
		}
	end

	local reason = ok and acceptedOrReason or acceptedOrReason
	local name = "ActionActorRejected"
	local message = self._name .. "." .. actionName .. " rejected actor"
	if reason ~= nil and reason ~= false then
		message ..= " (" .. tostring(reason) .. ")"
	end

	recordViolation(diagnostics, {
		level = "error",
		category = "action",
		system = self._name,
		name = name,
		message = message,
		context = context or {
			action = actionName,
		},
	})

	return {
		ok = false,
		name = name,
		reason = reason,
		message = message,
	}
end

function System.runAction(self: any, actionName: string, options: any?, handler: any?): any
	assertName("Action name", actionName)
	if type(options) == "function" and handler == nil then
		handler = options
		options = {}
	end
	options = options or {}

	if type(handler) ~= "function" then
		error("System.runAction expects an action handler function", 2)
	end

	local action = self._actions[actionName]
	local diagnostics = options.diagnostics
	if not action then
		local message = "unknown action contract: " .. tostring(actionName)
		recordViolation(diagnostics, {
			level = "error",
			category = "action",
			system = self._name,
			name = "UnknownAction",
			message = message,
			context = {
				action = actionName,
			},
		})
		return {
			ok = false,
			name = "UnknownAction",
			reason = message,
		}
	end

	local context = actionContext(options, self._name, actionName)
	local input = actionInput(options, context)
	context.payload = input
	context.input = input

	local inputValidation = self:validateActionInput(actionName, input, diagnostics, context)
	if not inputValidation.ok then
		return {
			ok = false,
			name = "ActionInputInvalid",
			reason = inputValidation.reason,
			context = context,
		}
	end
	context.payload = inputValidation.value
	context.input = inputValidation.value

	local contextValidation = self:validateActionContext(actionName, context, diagnostics)
	if not contextValidation.ok then
		return {
			ok = false,
			name = "ActionContextInvalid",
			reason = contextValidation.reason,
			context = context,
		}
	end

	local policy = self:checkActionPolicy(actionName, context, diagnostics)
	if not policy.ok then
		return {
			ok = false,
			name = policy.name,
			reason = policy.reason,
			context = context,
		}
	end

	local states = actionStates(options)
	local lifecycleRequirements = self:checkActionLifecycle(actionName, states, diagnostics, context)
	if not lifecycleRequirements.ok then
		return {
			ok = false,
			name = "ActionLifecycleStateInvalid",
			context = context,
			lifecycle = lifecycleRequirements,
		}
	end

	local preconditions = self:checkActionPreconditions(actionName, context, diagnostics)
	if not preconditions.ok then
		return {
			ok = false,
			name = "ActionPreconditionFailed",
			context = context,
			preconditions = preconditions,
		}
	end

	local scope = ActionScope.new(self, actionName, context, diagnostics)
	local ok, value = pcall(handler, scope)
	if not ok then
		local scopeViolation = ActionScope.violationResult(value)
		if scopeViolation ~= nil then
			return {
				ok = false,
				name = scopeViolation.name,
				reason = scopeViolation.reason,
				context = context,
				effects = scope:effects(),
			}
		end

		recordViolation(diagnostics, {
			level = "error",
			category = "action",
			system = self._name,
			name = "ActionHandlerError",
			message = tostring(value),
			context = context,
		})
		return {
			ok = false,
			name = "ActionHandlerError",
			reason = value,
			context = context,
			effects = scope:effects(),
		}
	end

	local outputValidation = self:validateActionOutput(actionName, value, diagnostics, context)
	if not outputValidation.ok then
		return {
			ok = false,
			name = "ActionOutputInvalid",
			reason = outputValidation.reason,
			value = value,
			context = context,
			effects = scope:effects(),
		}
	end

	context.result = outputValidation.value
	local postconditions = self:checkActionPostconditions(actionName, context, diagnostics)
	if not postconditions.ok then
		return {
			ok = false,
			name = "ActionPostconditionFailed",
			value = outputValidation.value,
			context = context,
			effects = scope:effects(),
			postconditions = postconditions,
		}
	end

	local lifecycle = self:reduceActionLifecycle(actionName, states, diagnostics, context)
	if not lifecycle.ok then
		return {
			ok = false,
			name = "ActionLifecycleTransitionInvalid",
			value = outputValidation.value,
			context = context,
			effects = scope:effects(),
			postconditions = postconditions,
			lifecycle = lifecycle,
		}
	end

	return {
		ok = true,
		name = actionName,
		value = outputValidation.value,
		context = context,
		effects = scope:effects(),
		preconditions = preconditions,
		postconditions = postconditions,
		lifecycle = lifecycle,
	}
end

function System.describe(self: any): Description
	local actions = {}
	for name, action in pairs(self._actions) do
		actions[name] = describeAction(action, self._preconditions, self._postconditions)
	end

	local remotes = {}
	for name, remote in pairs(self._remotes) do
		remotes[name] = {
			schema = remote.schema,
			options = copyMap(remote.options),
		}
	end

	local preconditions = {}
	for _, precondition in ipairs(self._preconditions) do
		table.insert(preconditions, precondition.name)
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
		actions = actions,
		remotes = remotes,
		preconditions = preconditions,
		postconditions = postconditions,
		lifecycles = copyMap(self._lifecycles),
	}
end

return System
