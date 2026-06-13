--!strict

local Result = require("./Result")
local Guards = require("./ActionRunnerGuards")

local Completion = {}

local function warnEagerEffectsNotRolledBack(
	systemContract: unknown,
	scope: any,
	diagnostics: unknown,
	actionName: string,
	context: { [unknown]: unknown }
)
	local eager = scope:eagerMutations()
	if #eager == 0 then
		return
	end

	Result.record(diagnostics, {
		level = "warn",
		category = "effect",
		system = Guards.systemName(systemContract),
		name = "ActionEagerEffectsNotRolledBack",
		message = "action "
			.. actionName
			.. " failed after running "
			.. tostring(#eager)
			.. " eager effect(s); only staged effects roll back, so these remain applied",
		context = {
			action = actionName,
			remote = context.remote,
			effects = eager,
		},
	})
end

local function tokenCancelReason(cancelToken: unknown): string
	local target = cancelToken :: any
	if target ~= nil and type(target.reason) == "function" then
		local reasonFn = target.reason :: (any) -> unknown
		return tostring(reasonFn(target))
	end
	return "cancelled"
end

local function isTokenCancelled(cancelToken: unknown): boolean
	local target = cancelToken :: any
	if target ~= nil and type(target.isCancelled) == "function" then
		local isCancelledFn = target.isCancelled :: (any) -> unknown
		return isCancelledFn(target) == true
	end
	return false
end

function Completion.handlerFailure(
	systemContract: unknown,
	diagnostics: unknown,
	context: { [unknown]: unknown },
	scope: any,
	value: unknown
): unknown
	local scopeViolation = scope.violationResult(value)
	if scopeViolation ~= nil then
		return {
			ok = false,
			name = scopeViolation.name,
			reason = scopeViolation.reason,
			context = context,
			effects = scope:effects(),
		}
	end

	Result.record(diagnostics, {
		level = "error",
		category = "action",
		system = Guards.systemName(systemContract),
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

function Completion.finish(
	systemContract: unknown,
	actionName: string,
	options: Guards.Options,
	prepared: Guards.PreparedRun,
	scope: any,
	value: unknown
): unknown
	local system = systemContract :: any
	local diagnostics = options.diagnostics
	local context = prepared.context :: { [unknown]: unknown }
	local states = prepared.states
	local preconditions = prepared.preconditions

	local cancelToken = options.cancelToken
	if isTokenCancelled(cancelToken) then
		local cancelReason = tokenCancelReason(cancelToken)
		local message = Guards.systemName(systemContract)
			.. "."
			.. actionName
			.. " was cancelled ("
			.. cancelReason
			.. "); staged effects were discarded"
		Result.record(diagnostics, {
			level = "warn",
			category = "action",
			system = Guards.systemName(systemContract),
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
	local outputValidation = system:validateActionOutput(actionName, value, diagnostics, context)
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
	local postconditions = system:checkActionPostconditions(actionName, context, diagnostics)
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

	local preparedLifecycle = system:reduceActionLifecycle(actionName, states, diagnostics, context)
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
		system = Guards.systemName(systemContract),
		action = actionName,
	}
	local commit = scope:commitEffects(diagnostics, effectOptions)
	context.effects = scope:effectView()
	if not commit.ok then
		warnEagerEffectsNotRolledBack(systemContract, scope, diagnostics, actionName, context)
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
	local session = prepared.session
	if session ~= nil and type((session :: any).apply) == "function" then
		local target = session :: any
		lifecycle = target:apply(actionName, diagnostics, context, prepared.sessionRevision)
	end

	if not lifecycle.ok then
		local rollback = scope:rollbackEffects(diagnostics, effectOptions)
		context.effects = scope:effectView()
		warnEagerEffectsNotRolledBack(systemContract, scope, diagnostics, actionName, context)
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

return Completion
