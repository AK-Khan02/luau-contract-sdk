--!strict

local ActionScope = require("./ActionScope")
local ContractReport = require("./ContractReport")
local LifecycleSession = require("./LifecycleSession")
local RemotePolicy = require("./RemotePolicy")
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
	ownership: {
		tags: {string},
		folders: {string},
	},
	permissions: {
		strict: boolean,
		mayRead: {string},
		mayWrite: {string},
		mustNeverTouch: {string},
	},
	actions: {[string]: ActionDescription},
	remotes: {[string]: any},
	preconditions: {string},
	postconditions: {string},
	lifecycles: {[string]: any},
	actorPolicies: {string},
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

local ASYNC_CONCURRENCY_MODES: {[string]: boolean} = {
	serialize = true,
	reject = true,
	allow = true,
}

local function normalizeAsyncPolicy(definition: any): any?
	if definition == nil or definition == false then
		return nil
	end
	if definition == true then
		definition = {}
	end
	if type(definition) ~= "table" then
		error("Action async policy must be true or a table", 3)
	end

	local concurrency = definition.concurrency
	if concurrency ~= nil and ASYNC_CONCURRENCY_MODES[concurrency] ~= true then
		error("Action async concurrency must be serialize, reject, or allow", 3)
	end

	local timeoutSeconds = definition.timeoutSeconds
	if timeoutSeconds ~= nil and timeoutSeconds ~= false then
		if type(timeoutSeconds) ~= "number" or timeoutSeconds <= 0 then
			error("Action async timeoutSeconds must be a positive number or false", 3)
		end
	end

	return {
		concurrency = concurrency,
		timeoutSeconds = timeoutSeconds,
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

local function normalizeRemoteDeclaration(remoteName: string, schemaOrDefinition: any, options: any?): (any, any?)
	if options ~= nil then
		return schemaOrDefinition, options
	end

	if type(schemaOrDefinition) ~= "table" then
		return schemaOrDefinition, options
	end

	local input = schemaOrDefinition.input or schemaOrDefinition.schema or schemaOrDefinition.payload
	if input == nil then
		return schemaOrDefinition, options
	end

	local remoteOptions = copyMap(schemaOrDefinition)
	remoteOptions.input = nil
	remoteOptions.schema = nil
	remoteOptions.payload = nil
	remoteOptions.name = remoteOptions.name or remoteOptions.remoteName or remoteName
	return input, remoteOptions
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

local function hasDeclaredBoundary(boundaries: {string}): boolean
	return #boundaries > 0
end

local function boundaryAllows(targetPath: string, boundaries: {string}): (boolean, string?)
	return matchesAnyBoundary(targetPath, boundaries)
end

local function combineForbiddenBoundaries(systemForbidden: {string}, action: any?): {string}
	local forbidden = copyList(systemForbidden)
	if action then
		for _, path in ipairs(action.forbids) do
			appendUnique(forbidden, path)
		end
	end
	return forbidden
end

local function declaredAccessBoundaries(action: any?, accessKind: string, systemReads: {string}, systemWrites: {string}): ({string}, {string})
	local systemBoundaries = accessKind == "read" and systemReads or systemWrites
	local actionBoundaries = {}
	if action then
		actionBoundaries = accessKind == "read" and action.reads or action.writes
	end
	return systemBoundaries, actionBoundaries
end

local function declaredEffectBoundaries(action: any?, effectKind: string): {string}
	if not action then
		return {}
	end
	if effectKind == "create" then
		return #action.creates > 0 and action.creates or action.writes
	end
	if effectKind == "destroy" then
		return #action.destroys > 0 and action.destroys or action.writes
	end
	if effectKind == "touch" then
		return #action.touches > 0 and action.touches or action.writes
	end
	return {}
end

local function permissionAllows(targetPath: string, boundaries: {string}, strict: boolean): (boolean, string?)
	if not hasDeclaredBoundary(boundaries) then
		return not strict, nil
	end
	return boundaryAllows(targetPath, boundaries)
end

local function permissionResult(
	ok: boolean,
	name: string,
	systemName: string,
	actionName: string?,
	kind: string,
	targetPath: string,
	reason: string?,
	extras: any?
): any
	local result = copyMap(extras or {})
	result.ok = ok
	result.name = name
	result.system = systemName
	result.action = actionName
	result.kind = kind
	result.target = targetPath
	result.reason = reason
	return result
end

local function permissionContext(baseContext: any?, actionName: string?, kind: string, targetPath: string, extras: any?): any
	local context = copyMap(baseContext or {})
	context.action = context.action or actionName
	context.kind = context.kind or kind
	context.target = context.target or targetPath

	for key, value in pairs(extras or {}) do
		context[key] = value
	end

	return context
end

local function recordViolation(diagnostics: any, fields: any): any
	if diagnostics and diagnostics.record then
		local target: any = diagnostics
		return target:record(fields)
	end
	return fields
end

-- Eager scope:write/create/destroy/touch apply immediately and are not
-- transactional, so a rollback leaves them in place. Surface that loudly so a
-- failed action that mutated state via eager effects is never silent.
local function warnEagerEffectsNotRolledBack(systemName: string, scope: any, diagnostics: any, actionName: string, context: any)
	local eager = scope:eagerMutations()
	if #eager == 0 then
		return
	end
	recordViolation(diagnostics, {
		level = "warn",
		category = "effect",
		system = systemName,
		name = "ActionEagerEffectsNotRolledBack",
		message = "action " .. actionName .. " failed after running " .. tostring(#eager)
			.. " eager effect(s); only staged effects roll back, so these remain applied",
		context = {
			action = actionName,
			remote = context.remote,
			effects = eager,
		},
	})
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
	local session = options.session
	if session and type(session.states) == "function" then
		local target: any = session
		return target:states()
	end
	return copyMap(options.states or {})
end

local function actionSession(options: any): any?
	if options.session ~= nil then
		return options.session
	end
	return nil
end

local function expectedLifecycleRevision(options: any): number?
	return options.expectedRevision or options.revision
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
		async = normalizeAsyncPolicy(definition.async),
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
		async = action.async ~= nil and copyMap(action.async) or nil,
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
		_strictPermissions = false,
		_actions = {},
		_remotes = {},
		_preconditions = {},
		_preconditionChecks = {},
		_postconditions = {},
		_postconditionChecks = {},
		_lifecycles = {},
		_actorPolicies = {},
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

function System.strictPermissions(self: any, enabled: boolean?): any
	self._strictPermissions = enabled ~= false
	return self
end

function System.remote(self: any, remoteName: string, schema: any, options: any?): any
	local remoteSchema, remoteOptions = normalizeRemoteDeclaration(remoteName, schema, options)
	self._remotes[remoteName] = RemotePolicy.normalize(remoteName, remoteSchema, remoteOptions)
	return self
end

function System.action(self: any, actionName: string, definition: any): any
	assertName("Action name", actionName)
	local action = buildAction(actionName, definition)
	self._actions[actionName] = action

	if action.remote ~= nil then
		local remoteName = action.remote.name
		local remote = RemotePolicy.normalize(remoteName, action.input or Schema.any(), action.remote, actionName)
		action.remote = remote
		self._remotes[remoteName] = remote
	end

	return self
end

function System.lifecycle(self: any, name: string, lifecycle: any): any
	assertName("Lifecycle name", name)
	self._lifecycles[name] = lifecycle
	return self
end

function System.lifecycleSession(self: any, initialStates: any?, options: any?): any
	return LifecycleSession.new(self, initialStates or {}, options)
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

function System.actorPolicy(self: any, name: string, check: (any, any) -> any): any
	assertName("Actor policy name", name)
	if type(check) ~= "function" then
		error("Actor policy check must be a function", 2)
	end

	self._actorPolicies[name] = check
	return self
end

function System.remoteOptions(self: any, remoteName: string): any?
	local remote = self._remotes[remoteName]
	if not remote then
		return nil
	end
	return RemotePolicy.options(remote)
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
	return remote.action :: string?
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

function System.validateRemoteResponse(self: any, remoteName: string, value: any, diagnostics: any?, context: any?): any
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
	if remote.response == nil then
		return {
			ok = true,
			value = value,
		}
	end

	local validation = Schema.validate(remote.response, value, "response")
	if not validation.ok then
		recordViolation(diagnostics, {
			level = "error",
			category = "remote",
			system = self._name,
			name = "RemoteResponseInvalid",
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

function System._unknownAction(self: any, actionName: string, diagnostics: any?, context: any?): any
	local message = "unknown action contract: " .. tostring(actionName)
	recordViolation(diagnostics, {
		level = "error",
		category = "action",
		system = self._name,
		name = "UnknownAction",
		message = message,
		context = permissionContext(context, actionName, "action", actionName, nil),
	})

	return permissionResult(false, "UnknownAction", self._name, actionName, "action", actionName, message, nil)
end

function System._checkForbiddenTouch(self: any, actionName: string?, targetPath: string, diagnostics: any?, context: any?, kind: string?): any
	assertName("Target path", targetPath)
	local action = actionName and self._actions[actionName]
	local forbidden = combineForbiddenBoundaries(self._mustNeverTouch, action)

	local matched, boundary = matchesAnyBoundary(targetPath, forbidden)
	if matched then
		local name = "ForbiddenTouch"
		local message = self._name .. " must never touch " .. tostring(boundary)
		recordViolation(diagnostics, {
			level = "error",
			category = "permission",
			system = self._name,
			name = name,
			message = message,
			context = permissionContext(context, actionName, kind or "touch", targetPath, {
				boundary = boundary,
			}),
		})
		return permissionResult(false, name, self._name, actionName, kind or "touch", targetPath, message, {
			strict = self._strictPermissions,
			forbiddenBoundary = boundary,
			forbiddenBoundaries = forbidden,
		})
	end

	return permissionResult(true, "PermissionAllowed", self._name, actionName, kind or "touch", targetPath, nil, {
		strict = self._strictPermissions,
		forbiddenBoundaries = forbidden,
	})
end

function System._checkPermission(self: any, actionName: string?, accessKind: string, targetPath: string, diagnostics: any?, context: any?): any
	assertName("Access kind", accessKind)
	assertName("Target path", targetPath)

	local action = nil
	if actionName ~= nil then
		action = self._actions[actionName]
		if action == nil then
			return self:_unknownAction(actionName, diagnostics, context)
		end
	end

	local forbidden = self:_checkForbiddenTouch(actionName, targetPath, diagnostics, context, accessKind)
	if not forbidden.ok then
		return forbidden
	end

	local systemBoundaries, actionBoundaries = declaredAccessBoundaries(action, accessKind, self._mayRead, self._mayWrite)
	local systemAllows, systemBoundary = permissionAllows(targetPath, systemBoundaries, self._strictPermissions)
	local actionAllows, actionBoundary = true, nil
	if action ~= nil then
		actionAllows, actionBoundary = permissionAllows(targetPath, actionBoundaries, self._strictPermissions)
	end

	local details = {
		strict = self._strictPermissions,
		systemBoundaries = copyList(systemBoundaries),
		actionBoundaries = copyList(actionBoundaries),
		matchedSystemBoundary = systemBoundary,
		matchedActionBoundary = actionBoundary,
	}

	if systemAllows and actionAllows then
		return permissionResult(true, "PermissionAllowed", self._name, actionName, accessKind, targetPath, nil, details)
	end

	local name = accessKind == "read" and "ReadNotAllowed" or "WriteNotAllowed"
	local subject = actionName and (self._name .. "." .. actionName) or self._name
	local message = subject .. " may not " .. accessKind .. " " .. targetPath
	details.systemAllowed = systemAllows
	details.actionAllowed = actionAllows

	recordViolation(diagnostics, {
		level = "error",
		category = "permission",
		system = self._name,
		name = name,
		message = message,
		context = permissionContext(context, actionName, accessKind, targetPath, details),
	})

	return permissionResult(false, name, self._name, actionName, accessKind, targetPath, message, details)
end

function System._checkWriteLikeEffect(self: any, actionName: string?, effectKind: string, targetPath: string, diagnostics: any?, context: any?): any
	local action = nil
	if actionName ~= nil then
		action = self._actions[actionName]
		if action == nil then
			return self:_unknownAction(actionName, diagnostics, context)
		end
	end

	local forbidden = self:_checkForbiddenTouch(actionName, targetPath, diagnostics, context, effectKind)
	if not forbidden.ok then
		return forbidden
	end

	local systemAllows, systemBoundary = permissionAllows(targetPath, self._mayWrite, self._strictPermissions)
	local actionBoundaries = declaredEffectBoundaries(action, effectKind)
	local actionAllows, actionBoundary = true, nil
	if action ~= nil then
		actionAllows, actionBoundary = permissionAllows(targetPath, actionBoundaries, self._strictPermissions)
	end

	local details = {
		strict = self._strictPermissions,
		systemBoundaries = copyList(self._mayWrite),
		actionBoundaries = copyList(actionBoundaries),
		matchedSystemBoundary = systemBoundary,
		matchedActionBoundary = actionBoundary,
	}

	if systemAllows and actionAllows then
		return permissionResult(true, "PermissionAllowed", self._name, actionName, effectKind, targetPath, nil, details)
	end

	local names = {
		create = "CreateNotAllowed",
		destroy = "DestroyNotAllowed",
		touch = "TouchNotAllowed",
	}
	local name = names[effectKind] or "EffectNotAllowed"
	local subject = actionName and (self._name .. "." .. actionName) or self._name
	local message = subject .. " may not " .. effectKind .. " " .. targetPath
	details.systemAllowed = systemAllows
	details.actionAllowed = actionAllows

	recordViolation(diagnostics, {
		level = "error",
		category = "permission",
		system = self._name,
		name = name,
		message = message,
		context = permissionContext(context, actionName, effectKind, targetPath, details),
	})

	return permissionResult(false, name, self._name, actionName, effectKind, targetPath, message, details)
end

function System._checkEffect(self: any, actionName: string?, effect: any, diagnostics: any?, context: any?): any
	if type(effect) ~= "table" then
		error("Effect must be a table", 3)
	end

	local kind = effect.kind or effect.type
	local targetPath = effect.target or effect.path
	assertName("Effect kind", kind)
	assertName("Effect target", targetPath)

	if kind == "read" then
		return self:_checkPermission(actionName, "read", targetPath, diagnostics, context)
	end
	if kind == "write" then
		return self:_checkPermission(actionName, "write", targetPath, diagnostics, context)
	end
	if kind == "create" or kind == "destroy" or kind == "touch" then
		return self:_checkWriteLikeEffect(actionName, kind, targetPath, diagnostics, context)
	end

	local name = "UnknownEffectKind"
	local message = "unknown action effect kind: " .. tostring(kind)
	recordViolation(diagnostics, {
		level = "error",
		category = "action",
		system = self._name,
		name = name,
		message = message,
		context = permissionContext(context, actionName, tostring(kind), tostring(targetPath), nil),
	})

	return permissionResult(false, name, self._name, actionName, tostring(kind), tostring(targetPath), message, nil)
end

function System.checkPermission(self: any, actionName: string?, accessKind: string, targetPath: string, diagnostics: any?, context: any?): any
	return self:_checkPermission(actionName, accessKind, targetPath, diagnostics, context)
end

function System.checkRead(self: any, targetPath: any, diagnostics: any?, context: any?, legacyContext: any?): any
	if type(diagnostics) == "string" then
		return self:checkActionRead(targetPath, diagnostics, context, legacyContext)
	end
	return self:_checkPermission(nil, "read", targetPath, diagnostics, context)
end

function System.checkWrite(self: any, targetPath: any, diagnostics: any?, context: any?, legacyContext: any?): any
	if type(diagnostics) == "string" then
		return self:checkActionWrite(targetPath, diagnostics, context, legacyContext)
	end
	return self:_checkPermission(nil, "write", targetPath, diagnostics, context)
end

function System.checkEffect(self: any, effect: any, diagnostics: any?, context: any?, legacyContext: any?): any
	if type(effect) == "string" and type(diagnostics) == "table" then
		return self:checkActionEffect(effect, diagnostics, context, legacyContext)
	end
	return self:_checkEffect(nil, effect, diagnostics, context)
end

function System.checkEffects(self: any, effects: {any}, diagnostics: any?, context: any?): any
	local failures = {}
	local results = {}

	for _, effect in ipairs(effects or {}) do
		local result = self:checkEffect(effect, diagnostics, context)
		table.insert(results, result)
		if not result.ok then
			table.insert(failures, result)
		end
	end

	return {
		ok = #failures == 0,
		results = results,
		failures = failures,
	}
end

function System.checkActionRead(self: any, actionName: string, targetPath: string, diagnostics: any?, context: any?): any
	assertName("Action name", actionName)
	return self:_checkPermission(actionName, "read", targetPath, diagnostics, context)
end

function System.checkActionWrite(self: any, actionName: string, targetPath: string, diagnostics: any?, context: any?): any
	assertName("Action name", actionName)
	return self:_checkPermission(actionName, "write", targetPath, diagnostics, context)
end

function System.checkActionEffect(self: any, actionName: string, effect: any, diagnostics: any?, context: any?): any
	assertName("Action name", actionName)
	return self:_checkEffect(actionName, effect, diagnostics, context)
end

function System.checkActionEffects(self: any, actionName: string, effects: {any}, diagnostics: any?, context: any?): any
	assertName("Action name", actionName)

	local failures = {}
	local results = {}
	for _, effect in ipairs(effects or {}) do
		local result = self:checkActionEffect(actionName, effect, diagnostics, context)
		table.insert(results, result)
		if not result.ok then
			table.insert(failures, result)
		end
	end

	return {
		ok = #failures == 0,
		results = results,
		failures = failures,
	}
end

function System.checkForbiddenTouch(self: any, actionName: string?, targetPath: string, diagnostics: any?, context: any?): any
	return self:_checkForbiddenTouch(actionName, targetPath, diagnostics, context, "touch")
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

function System._actorFailure(
	self: any,
	ownerKind: string,
	ownerName: string,
	failure: string,
	message: string,
	reason: any?,
	context: any?,
	diagnostics: any?
): any
	local diagnosticName = "ActionActorRejected"
	if ownerKind == "remote" then
		diagnosticName = "Remote" .. failure
	elseif failure == "ActorPolicyUnknown" then
		diagnosticName = "ActionActorPolicyUnknown"
	end

	local failureContext = copyMap(context or {})
	failureContext[ownerKind] = ownerName

	recordViolation(diagnostics, {
		level = "error",
		category = ownerKind,
		system = self._name,
		name = diagnosticName,
		message = message,
		context = failureContext,
	})

	return {
		ok = false,
		name = diagnosticName,
		reason = reason or message,
		message = message,
	}
end

function System._checkActorPolicy(
	self: any,
	ownerKind: string,
	ownerName: string,
	actorPolicy: any,
	actor: any,
	context: any?,
	diagnostics: any?
): any
	if actorPolicy == nil then
		return {
			ok = true,
		}
	end

	local subject = self._name .. "." .. ownerName
	if actorPolicy == true or actorPolicy == "required" then
		if actor ~= nil then
			return {
				ok = true,
			}
		end
		return self:_actorFailure(
			ownerKind,
			ownerName,
			"ActorRequired",
			subject .. " requires an actor",
			nil,
			context,
			diagnostics
		)
	end

	local check = actorPolicy
	local policyName = nil
	if type(actorPolicy) == "string" then
		policyName = actorPolicy
		check = self._actorPolicies[actorPolicy]
	elseif type(actorPolicy) == "table" then
		policyName = actorPolicy.name or actorPolicy.policy
		check = actorPolicy.check or actorPolicy.authorize
		if actorPolicy.required == true and actor == nil then
			return self:_actorFailure(
				ownerKind,
				ownerName,
				"ActorRequired",
				subject .. " requires an actor",
				nil,
				context,
				diagnostics
			)
		end
	end

	if type(check) ~= "function" then
		local missingName = policyName or tostring(actorPolicy)
		return self:_actorFailure(
			ownerKind,
			ownerName,
			"ActorPolicyUnknown",
			subject .. " references unknown actor policy " .. tostring(missingName),
			missingName,
			context,
			diagnostics
		)
	end

	local ok, acceptedOrReason = pcall(check, actor, context or {})
	if ok and acceptedOrReason == true then
		return {
			ok = true,
		}
	end

	local reason = ok and acceptedOrReason or acceptedOrReason
	local message = subject .. " rejected actor"
	if reason ~= nil and reason ~= false then
		message ..= " (" .. tostring(reason) .. ")"
	end

	return self:_actorFailure(ownerKind, ownerName, "ActorRejected", message, reason, context, diagnostics)
end

function System.checkRemoteActor(self: any, remoteName: string, actor: any, context: any?, diagnostics: any?): any
	assertName("Remote name", remoteName)
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
			name = "UnknownRemote",
			reason = message,
		}
	end

	local actorContext = copyMap(context or {})
	actorContext.actor = actorContext.actor or actor
	actorContext.player = actorContext.player or actor
	actorContext.remote = actorContext.remote or remoteName

	return self:_checkActorPolicy("remote", remoteName, remote.actor, actor, actorContext, diagnostics)
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
	if actorPolicy == nil and policy.actorRequired == true then
		actorPolicy = "required"
	elseif policy.actorRequired == true and (context == nil or context.actor == nil) then
		return self:_checkActorPolicy("action", actionName, "required", nil, context, diagnostics)
	end

	local actor = context and context.actor or nil
	return self:_checkActorPolicy("action", actionName, actorPolicy, actor, context, diagnostics)
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
	context.cancelToken = options.cancelToken

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

	local session = actionSession(options)
	local expectedRevision = expectedLifecycleRevision(options)
	local states = actionStates(options)
	local sessionRevision = nil
	local lifecycleRequirements = nil
	if session ~= nil and type(session.canRun) == "function" then
		local target: any = session
		lifecycleRequirements = target:canRun(actionName, diagnostics, context, expectedRevision)
		sessionRevision = lifecycleRequirements.revision
		states = lifecycleRequirements.states or states
	else
		lifecycleRequirements = self:checkActionLifecycle(actionName, states, diagnostics, context)
	end

	if not lifecycleRequirements.ok then
		return {
			ok = false,
			name = lifecycleRequirements.name or "ActionLifecycleStateInvalid",
			reason = lifecycleRequirements.reason,
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
	context.effects = scope:effectView()
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

	local cancelToken: any = options.cancelToken
	local tokenCancelled = false
	if cancelToken ~= nil and type(cancelToken.isCancelled) == "function" then
		local isCancelledFn = cancelToken.isCancelled :: (any) -> any
		tokenCancelled = isCancelledFn(cancelToken) == true
	end
	if tokenCancelled then
		local cancelReason = "cancelled"
		if type(cancelToken.reason) == "function" then
			local reasonFn = cancelToken.reason :: (any) -> any
			cancelReason = tostring(reasonFn(cancelToken))
		end
		local message = self._name .. "." .. actionName .. " was cancelled (" .. cancelReason
			.. "); staged effects were discarded"
		recordViolation(diagnostics, {
			level = "warn",
			category = "action",
			system = self._name,
			name = "ActionCancelled",
			message = message,
			context = context,
		})
		return {
			ok = false,
			name = "ActionCancelled",
			reason = message,
			cancelReason = cancelReason,
			context = context,
			effects = scope:effects(),
		}
	end

	context.effects = scope:effectView()
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
	context.effects = scope:effectView()
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

	local preparedLifecycle = self:reduceActionLifecycle(actionName, states, diagnostics, context)
	if not preparedLifecycle.ok then
		return {
			ok = false,
			name = preparedLifecycle.name or "ActionLifecycleTransitionInvalid",
			reason = preparedLifecycle.reason,
			value = outputValidation.value,
			context = context,
			effects = scope:effects(),
			postconditions = postconditions,
			lifecycle = preparedLifecycle,
		}
	end

	local effectOptions = {
		system = self._name,
		action = actionName,
	}
	local commit = scope:commitEffects(diagnostics, effectOptions)
	context.effects = scope:effectView()
	if not commit.ok then
		warnEagerEffectsNotRolledBack(self._name, scope, diagnostics, actionName, context)
		return {
			ok = false,
			name = commit.name,
			reason = commit.reason,
			value = outputValidation.value,
			context = context,
			effects = scope:effects(),
			postconditions = postconditions,
			lifecycle = preparedLifecycle,
			commit = commit,
			rollback = commit.rollback,
		}
	end

	local lifecycle = preparedLifecycle
	if session ~= nil and type(session.apply) == "function" then
		local target: any = session
		lifecycle = target:apply(actionName, diagnostics, context, sessionRevision)
	end

	if not lifecycle.ok then
		local rollback = scope:rollbackEffects(diagnostics, effectOptions)
		context.effects = scope:effectView()
		warnEagerEffectsNotRolledBack(self._name, scope, diagnostics, actionName, context)
		return {
			ok = false,
			name = lifecycle.name or "ActionLifecycleTransitionInvalid",
			reason = lifecycle.reason,
			value = outputValidation.value,
			context = context,
			effects = scope:effects(),
			postconditions = postconditions,
			lifecycle = lifecycle,
			commit = commit,
			rollback = rollback,
		}
	end

	context.effects = scope:effectView()
	return {
		ok = true,
		name = actionName,
		value = outputValidation.value,
		context = context,
		effects = scope:effects(),
		preconditions = preconditions,
		postconditions = postconditions,
		lifecycle = lifecycle,
		commit = commit,
	}
end

function System.describe(self: any): Description
	return ContractReport.describeSystem(self)
end

return System
