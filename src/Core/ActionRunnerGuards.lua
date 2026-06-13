--!strict

local Result = require("./Result")
local TableUtil = require("./TableUtil")

export type Options = {
	actor: unknown?,
	payload: unknown?,
	context: { [unknown]: unknown }?,
	diagnostics: unknown?,
	session: unknown?,
	states: { [string]: unknown }?,
	expectedRevision: unknown?,
	revision: unknown?,
	remote: string?,
	cancelToken: unknown?,
}

export type PreparedRun = {
	ok: boolean,
	context: { [unknown]: unknown }?,
	states: unknown?,
	session: unknown?,
	sessionRevision: unknown?,
	preconditions: unknown?,
	failure: unknown?,
}

local Guards = {}

local copyMap = TableUtil.copyMap

function Guards.systemName(systemContract: unknown): string
	local target = systemContract :: any
	if target ~= nil and type(target.name) == "function" then
		local nameFn = target.name :: (any) -> string
		return nameFn(target)
	end
	return "unknown"
end

local function actionContext(options: Options, systemContract: unknown, actionName: string): { [unknown]: unknown }
	local source = options.context or {}
	local context = copyMap(source)

	context.action = context.action or actionName
	context.system = context.system or Guards.systemName(systemContract)

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

local function actionInput(options: Options, context: { [unknown]: unknown }): unknown
	if options.payload ~= nil then
		return options.payload
	end
	return context.input or context.payload
end

local function actionStates(options: Options): unknown
	local session = options.session
	if session ~= nil and type((session :: any).states) == "function" then
		local target = session :: any
		return target:states()
	end
	return copyMap(options.states or {})
end

local function expectedLifecycleRevision(options: Options): unknown?
	return options.expectedRevision or options.revision
end

local function unknownAction(systemContract: unknown, actionName: string, diagnostics: unknown): unknown
	local message = "unknown action contract: " .. tostring(actionName)
	Result.record(diagnostics, {
		level = "error",
		category = "action",
		system = Guards.systemName(systemContract),
		name = "UnknownAction",
		message = message,
		context = {
			action = actionName,
		},
	})
	return Result.fail("UnknownAction", message)
end

local function failure(
	name: string,
	reason: unknown?,
	context: { [unknown]: unknown },
	fields: { [string]: unknown }?
): PreparedRun
	local details = copyMap(fields or {})
	details.ok = false
	details.name = name
	details.reason = reason
	details.context = context

	return {
		ok = false,
		failure = details,
	}
end

function Guards.prepare(systemContract: unknown, actionName: string, options: Options): PreparedRun
	local diagnostics = options.diagnostics
	local system = systemContract :: any
	local hasAction = system.hasAction
	if type(hasAction) ~= "function" then
		return {
			ok = false,
			failure = unknownAction(systemContract, actionName, diagnostics),
		}
	end
	local hasActionFn = hasAction :: (any, string) -> boolean
	if not hasActionFn(system, actionName) then
		return {
			ok = false,
			failure = unknownAction(systemContract, actionName, diagnostics),
		}
	end

	local context = actionContext(options, systemContract, actionName)
	local input = actionInput(options, context)
	context.payload = input
	context.input = input
	context.cancelToken = options.cancelToken

	local inputValidation = system:validateActionInput(actionName, input, diagnostics, context)
	if not inputValidation.ok then
		return failure("ActionInputInvalid", inputValidation.reason, context, nil)
	end
	context.payload = inputValidation.value
	context.input = inputValidation.value

	local contextValidation = system:validateActionContext(actionName, context, diagnostics)
	if not contextValidation.ok then
		return failure("ActionContextInvalid", contextValidation.reason, context, nil)
	end

	local policy = system:checkActionPolicy(actionName, context, diagnostics)
	if not policy.ok then
		return failure(policy.name, policy.reason, context, nil)
	end

	local session = options.session
	local expectedRevision = expectedLifecycleRevision(options)
	local states = actionStates(options)
	local sessionRevision = nil
	local lifecycleRequirements = nil
	if session ~= nil and type((session :: any).canRun) == "function" then
		local target = session :: any
		lifecycleRequirements = target:canRun(actionName, diagnostics, context, expectedRevision)
		sessionRevision = lifecycleRequirements.revision
		states = lifecycleRequirements.states or states
	else
		lifecycleRequirements = system:checkActionLifecycle(actionName, states, diagnostics, context)
	end

	if not lifecycleRequirements.ok then
		return failure(
			lifecycleRequirements.name or "ActionLifecycleStateInvalid",
			lifecycleRequirements.reason,
			context,
			{
				lifecycle = lifecycleRequirements,
			}
		)
	end

	local preconditions = system:checkActionPreconditions(actionName, context, diagnostics)
	if not preconditions.ok then
		return failure("ActionPreconditionFailed", nil, context, {
			preconditions = preconditions,
		})
	end

	return {
		ok = true,
		context = context,
		states = states,
		session = session,
		sessionRevision = sessionRevision,
		preconditions = preconditions,
	}
end

return Guards
