--!strict

local Names = require("./Names")
local PermissionCompat = require("./SystemPermissionCompat")
local Result = require("./Result")
local TableUtil = require("./TableUtil")

local SystemPermissions = {}

local assertName = Names.assertName
local appendUnique = TableUtil.appendUnique
local copyList = TableUtil.copyList
local copyMap = TableUtil.copyMap
local recordViolation = Result.record

local function matchesBoundary(target: any, boundary: string): boolean
	if target == boundary then
		return true
	end
	return type(target) == "string" and string.sub(target, 1, #boundary + 1) == boundary .. "."
end

local function matchesAnyBoundary(target: string, boundaries: { string }): (boolean, string?)
	for _, boundary in ipairs(boundaries) do
		if matchesBoundary(target, boundary) then
			return true, boundary
		end
	end
	return false, nil
end

local function hasDeclaredBoundary(boundaries: { string }): boolean
	return #boundaries > 0
end

local function boundaryAllows(targetPath: string, boundaries: { string }): (boolean, string?)
	return matchesAnyBoundary(targetPath, boundaries)
end

local function combineForbiddenBoundaries(systemForbidden: { string }, action: any?): { string }
	local forbidden = copyList(systemForbidden)
	if action then
		for _, path in ipairs(action.forbids) do
			appendUnique(forbidden, path)
		end
	end
	return forbidden
end

local function declaredAccessBoundaries(
	action: any?,
	accessKind: string,
	systemReads: { string },
	systemWrites: { string }
): ({ string }, { string })
	local systemBoundaries = accessKind == "read" and systemReads or systemWrites
	local actionBoundaries = {}
	if action then
		actionBoundaries = accessKind == "read" and action.reads or action.writes
	end
	return systemBoundaries, actionBoundaries
end

local function declaredEffectBoundaries(action: any?, effectKind: string): { string }
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

local function permissionAllows(targetPath: string, boundaries: { string }, strict: boolean): (boolean, string?)
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

local function permissionContext(
	baseContext: any?,
	actionName: string?,
	kind: string,
	targetPath: string,
	extras: any?
): any
	local context = copyMap(baseContext or {})
	context.action = context.action or actionName
	context.kind = context.kind or kind
	context.target = context.target or targetPath

	for key, value in pairs(extras or {}) do
		context[key] = value
	end

	return context
end

function SystemPermissions._unknownAction(self: any, actionName: string, diagnostics: any?, context: any?): any
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

function SystemPermissions._checkForbiddenTouch(
	self: any,
	actionName: string?,
	targetPath: string,
	diagnostics: any?,
	context: any?,
	kind: string?
): any
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

function SystemPermissions._checkPermission(
	self: any,
	actionName: string?,
	accessKind: string,
	targetPath: string,
	diagnostics: any?,
	context: any?
): any
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

	local systemBoundaries, actionBoundaries =
		declaredAccessBoundaries(action, accessKind, self._mayRead, self._mayWrite)
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

function SystemPermissions._checkWriteLikeEffect(
	self: any,
	actionName: string?,
	effectKind: string,
	targetPath: string,
	diagnostics: any?,
	context: any?
): any
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

function SystemPermissions._checkEffect(
	self: any,
	actionName: string?,
	effect: any,
	diagnostics: any?,
	context: any?
): any
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

function SystemPermissions.checkPermission(
	self: any,
	actionName: string?,
	accessKind: string,
	targetPath: string,
	diagnostics: any?,
	context: any?
): any
	return self:_checkPermission(actionName, accessKind, targetPath, diagnostics, context)
end

function SystemPermissions.checkRead(
	self: any,
	targetPath: any,
	diagnostics: any?,
	context: any?,
	legacyContext: any?
): any
	local request = PermissionCompat.access(targetPath, diagnostics, context, legacyContext)
	if request.actionName ~= nil then
		return self:checkActionRead(request.actionName, request.targetPath, request.diagnostics, request.context)
	end
	return self:_checkPermission(nil, "read", request.targetPath, request.diagnostics, request.context)
end

function SystemPermissions.checkWrite(
	self: any,
	targetPath: any,
	diagnostics: any?,
	context: any?,
	legacyContext: any?
): any
	local request = PermissionCompat.access(targetPath, diagnostics, context, legacyContext)
	if request.actionName ~= nil then
		return self:checkActionWrite(request.actionName, request.targetPath, request.diagnostics, request.context)
	end
	return self:_checkPermission(nil, "write", request.targetPath, request.diagnostics, request.context)
end

function SystemPermissions.checkEffect(
	self: any,
	effect: any,
	diagnostics: any?,
	context: any?,
	legacyContext: any?
): any
	local request = PermissionCompat.effect(effect, diagnostics, context, legacyContext)
	if request.actionName ~= nil then
		return self:checkActionEffect(request.actionName, request.effect, request.diagnostics, request.context)
	end
	return self:_checkEffect(nil, request.effect, request.diagnostics, request.context)
end

function SystemPermissions.checkEffects(self: any, effects: { any }, diagnostics: any?, context: any?): any
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

function SystemPermissions.checkActionRead(
	self: any,
	actionName: string,
	targetPath: string,
	diagnostics: any?,
	context: any?
): any
	assertName("Action name", actionName)
	return self:_checkPermission(actionName, "read", targetPath, diagnostics, context)
end

function SystemPermissions.checkActionWrite(
	self: any,
	actionName: string,
	targetPath: string,
	diagnostics: any?,
	context: any?
): any
	assertName("Action name", actionName)
	return self:_checkPermission(actionName, "write", targetPath, diagnostics, context)
end

function SystemPermissions.checkActionEffect(
	self: any,
	actionName: string,
	effect: any,
	diagnostics: any?,
	context: any?
): any
	assertName("Action name", actionName)
	return self:_checkEffect(actionName, effect, diagnostics, context)
end

function SystemPermissions.checkActionEffects(
	self: any,
	actionName: string,
	effects: { any },
	diagnostics: any?,
	context: any?
): any
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

function SystemPermissions.checkForbiddenTouch(
	self: any,
	actionName: string?,
	targetPath: string,
	diagnostics: any?,
	context: any?
): any
	return self:_checkForbiddenTouch(actionName, targetPath, diagnostics, context, "touch")
end

function SystemPermissions.checkTouch(
	self: any,
	actionName: string,
	targetPath: string,
	diagnostics: any?,
	context: any?
): any
	return self:checkForbiddenTouch(actionName, targetPath, diagnostics, context)
end
return SystemPermissions
