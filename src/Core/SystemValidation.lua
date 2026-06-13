--!strict

local Result = require("./Result")
local Schema = require("./Schema")

local SystemValidation = {}

local recordViolation = Result.record

function SystemValidation.validateRemote(
	self: any,
	remoteName: string,
	payload: any,
	diagnostics: any?,
	context: any?
): any
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

function SystemValidation.validateRemoteResponse(
	self: any,
	remoteName: string,
	value: any,
	diagnostics: any?,
	context: any?
): any
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

function SystemValidation.validateActionInput(
	self: any,
	actionName: string,
	payload: any,
	diagnostics: any?,
	context: any?
): any
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

function SystemValidation.validateActionOutput(
	self: any,
	actionName: string,
	value: any,
	diagnostics: any?,
	context: any?
): any
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

function SystemValidation.validateActionContext(self: any, actionName: string, context: any, diagnostics: any?): any
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
return SystemValidation
