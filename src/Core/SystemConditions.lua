--!strict

local Names = require("./Names")
local Result = require("./Result")

local SystemConditions = {}

local assertName = Names.assertName
local recordViolation = Result.record

local function checkNames(references: any, fallback: { any }?): { string }
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

function SystemConditions.checkPrecondition(self: any, name: string, context: any?, diagnostics: any?): any
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

function SystemConditions.checkPreconditions(self: any, context: any?, diagnostics: any?, references: any?): any
	local failures = {}
	local names = references == nil and checkNames("all", self._preconditions)
		or checkNames(references, self._preconditions)

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

function SystemConditions.checkPostcondition(self: any, name: string, context: any?, diagnostics: any?): any
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

function SystemConditions.checkPostconditions(self: any, context: any?, diagnostics: any?, references: any?): any
	local failures = {}
	local names = references == nil and checkNames("all", self._postconditions)
		or checkNames(references, self._postconditions)

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

function SystemConditions.checkActionPreconditions(self: any, actionName: string, context: any?, diagnostics: any?): any
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

function SystemConditions.checkActionPostconditions(
	self: any,
	actionName: string,
	context: any?,
	diagnostics: any?
): any
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
return SystemConditions
