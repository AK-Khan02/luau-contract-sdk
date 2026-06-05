--!strict

export type EffectReport = {
	kind: string,
	target: string,
	status: string,
	metadata: any?,
	result: any?,
	error: string?,
}

local EffectPlan: any = {}
EffectPlan.__index = EffectPlan

local EffectView: any = {}
EffectView.__index = EffectView

local function copyKey(key: any): any
	local keyType = type(key)
	if keyType == "string" or keyType == "number" or keyType == "boolean" then
		return key
	end
	return tostring(key)
end

local function copyValue(value: any, seen: any?): any
	local valueType = type(value)
	if valueType == "function" then
		return {
			kind = "function",
		}
	end
	if valueType ~= "table" then
		if valueType == "string" or valueType == "number" or valueType == "boolean" or value == nil then
			return value
		end
		return {
			kind = valueType,
			value = tostring(value),
		}
	end

	local visited = seen or {}
	if visited[value] then
		return {
			kind = "cycle",
		}
	end
	visited[value] = true

	local copy = {}
	for key, child in pairs(value) do
		copy[copyKey(key)] = copyValue(child, visited)
	end
	visited[value] = nil
	return copy
end

local function copyReports(effects: {any}): {EffectReport}
	local reports = {}
	for index, effect in ipairs(effects) do
		reports[index] = {
			kind = effect.kind,
			target = effect.target,
			status = effect.status,
			metadata = copyValue(effect.metadata),
			result = copyValue(effect.result),
			error = effect.error,
		}
	end
	return reports
end

local function assertEffect(kind: any, targetPath: any)
	if type(kind) ~= "string" or kind == "" then
		error("Effect kind must be a non-empty string", 3)
	end
	if type(targetPath) ~= "string" or targetPath == "" then
		error("Effect target must be a non-empty string", 3)
	end
end

local function normalizeOperation(operation: any): any
	if type(operation) == "function" then
		return {
			commit = operation,
		}
	end
	if type(operation) == "table" then
		if type(operation.commit) ~= "function" then
			error("Staged effect table must include a commit function", 3)
		end
		if operation.rollback ~= nil and type(operation.rollback) ~= "function" then
			error("Staged effect rollback must be a function", 3)
		end
		return {
			commit = operation.commit,
			rollback = operation.rollback,
			metadata = copyValue(operation.metadata),
		}
	end
	error("Staged effect expects a commit function or effect table", 3)
end

local function record(diagnostics: any, fields: any): any
	if diagnostics and diagnostics.record then
		local target: any = diagnostics
		return target:record(fields)
	end
	return fields
end

local function diagnosticContext(context: any?, options: any, effect: any): any
	local output = {
		system = options.system,
		action = options.action,
		kind = effect.kind,
		target = effect.target,
	}

	if type(context) == "table" then
		output.actor = context.actor
		output.remote = context.remote
	end

	return output
end

local function recordEffectFailure(diagnostics: any, name: string, message: string, context: any?, options: any, effect: any)
	record(diagnostics, {
		level = "error",
		category = "effect",
		system = options.system,
		name = name,
		message = message,
		context = diagnosticContext(context, options, effect),
	})
end

local function matchesMetadata(metadata: any, criteria: any): boolean
	for key, value in pairs(criteria or {}) do
		if metadata == nil or metadata[key] ~= value then
			return false
		end
	end
	return true
end

local function matchesEffect(effect: any, criteria: any): boolean
	for key, value in pairs(criteria or {}) do
		if key == "metadata" then
			if not matchesMetadata(effect.metadata, value) then
				return false
			end
		elseif effect[key] ~= value and (effect.metadata == nil or effect.metadata[key] ~= value) then
			return false
		end
	end
	return true
end

function EffectView.has(self: any, criteria: any): boolean
	for _, effect in ipairs(self._effects) do
		if matchesEffect(effect, criteria or {}) then
			return true
		end
	end
	return false
end

function EffectView.describe(self: any): {EffectReport}
	return copyReports(self._effects)
end

function EffectPlan.new(): any
	return setmetatable({
		_effects = {},
	}, EffectPlan)
end

function EffectPlan.record(self: any, kind: string, targetPath: string, status: string?, metadata: any?): any
	assertEffect(kind, targetPath)
	local effect = {
		kind = kind,
		target = targetPath,
		status = status or "committed",
		metadata = copyValue(metadata),
		transactional = false,
	}
	table.insert(self._effects, effect)
	return copyReports({ effect })[1]
end

function EffectPlan.stage(self: any, kind: string, targetPath: string, operation: any): any
	assertEffect(kind, targetPath)
	local normalized = normalizeOperation(operation)
	local effect = {
		kind = kind,
		target = targetPath,
		status = "planned",
		metadata = normalized.metadata,
		commit = normalized.commit,
		rollback = normalized.rollback,
		transactional = true,
	}
	table.insert(self._effects, effect)
	return copyReports({ effect })[1]
end

function EffectPlan.effects(self: any): {EffectReport}
	return copyReports(self._effects)
end

function EffectPlan.view(self: any): any
	return setmetatable({
		_effects = self:effects(),
	}, EffectView)
end

function EffectPlan.has(self: any, criteria: any): boolean
	for _, effect in ipairs(self._effects) do
		if matchesEffect(effect, criteria or {}) then
			return true
		end
	end
	return false
end

function EffectPlan.rollback(self: any, context: any?, diagnostics: any?, options: any?): any
	local config = options or {}
	local failures = {}
	local rolledBack = 0

	for index = #self._effects, 1, -1 do
		local effect = self._effects[index]
		if effect.transactional == true and effect.status == "committed" then
			if type(effect.rollback) == "function" then
				local rollback: any = effect.rollback
				local ok, reason = pcall(rollback, context)
				if ok then
					effect.status = "rolledBack"
					rolledBack += 1
				else
					effect.status = "rollbackFailed"
					effect.error = tostring(reason)
					local message = "effect rollback failed: " .. tostring(reason)
					recordEffectFailure(diagnostics, "ActionRollbackFailed", message, context, config, effect)
					table.insert(failures, {
						name = "ActionRollbackFailed",
						reason = message,
						effect = copyReports({ effect })[1],
					})
				end
			else
				effect.status = "rollbackUnavailable"
				local message = "effect rollback unavailable for " .. tostring(effect.target)
				recordEffectFailure(diagnostics, "ActionRollbackUnavailable", message, context, config, effect)
				table.insert(failures, {
					name = "ActionRollbackUnavailable",
					reason = message,
					effect = copyReports({ effect })[1],
				})
			end
		end
	end

	return {
		ok = #failures == 0,
		name = #failures == 0 and "EffectPlanRolledBack" or "EffectPlanRollbackFailed",
		rolledBack = rolledBack,
		failures = failures,
		effects = self:effects(),
	}
end

function EffectPlan.commit(self: any, context: any?, diagnostics: any?, options: any?): any
	local config = options or {}
	local committed = 0

	for _, effect in ipairs(self._effects) do
		if effect.transactional == true and effect.status == "planned" then
			effect.status = "committing"
			local ok, value = pcall(effect.commit, context)
			if ok then
				effect.status = "committed"
				effect.result = value
				committed += 1
			else
				effect.status = "failed"
				effect.error = tostring(value)
				local message = "effect commit failed: " .. tostring(value)
				recordEffectFailure(diagnostics, "ActionCommitFailed", message, context, config, effect)
				local rollback = self:rollback(context, diagnostics, config)
				return {
					ok = false,
					name = "ActionCommitFailed",
					reason = message,
					committed = committed,
					rollback = rollback,
					effects = self:effects(),
				}
			end
		end
	end

	return {
		ok = true,
		name = "EffectPlanCommitted",
		committed = committed,
		effects = self:effects(),
	}
end

return EffectPlan
