--!strict

local AsyncGate = require("./AsyncGate")
local Names = require("./Names")

export type Invocation = {
	system: any,
	action: string,
	actor: any?,
	payload: any?,
	context: any?,
	diagnostics: any?,
	session: any?,
	states: any?,
	expectedRevision: any?,
	remote: string?,
	handler: any,
	handlerRequest: any?,
	asyncPolicy: any?,
	asyncGate: any?,
	asyncGateResolver: (() -> any)?,
	asyncKey: any?,
	asyncFallbackKey: any?,
	pipeline: any?,
	validated: boolean?,
}

local ActionInvoker = {}

local assertName = Names.assertName

local function systemName(systemContract: any): string
	if systemContract ~= nil and type(systemContract.name) == "function" then
		local target: any = systemContract
		return target:name()
	end
	return "unknown"
end

function ActionInvoker.asyncPolicy(systemContract: any, actionName: string): any?
	if systemContract == nil or type(systemContract.actionOptions) ~= "function" then
		return nil
	end

	local target: any = systemContract
	local actionOptions = target:actionOptions(actionName)
	if actionOptions == nil then
		return nil
	end
	return actionOptions.async
end

local function asyncKey(invocation: Invocation): any
	if invocation.asyncKey ~= nil then
		return invocation.asyncKey
	end
	if invocation.session ~= nil then
		return invocation.session
	end
	if invocation.actor ~= nil then
		return invocation.actor
	end
	if invocation.asyncFallbackKey ~= nil then
		return invocation.asyncFallbackKey
	end
	return invocation.action
end

local function resolveAsyncGate(invocation: Invocation): any
	if invocation.asyncGate ~= nil then
		return invocation.asyncGate
	end

	local resolver = invocation.asyncGateResolver
	if resolver ~= nil then
		return resolver()
	end

	return nil
end

local function runWithAsyncGate(invocation: Invocation, asyncPolicy: any, execute: any, onStarted: any): any
	local gate = resolveAsyncGate(invocation)
	if gate == nil then
		error("ActionInvoker.run needs an asyncGate for async action " .. invocation.action, 3)
	end

	return gate:run(asyncKey(invocation), {
		concurrency = AsyncGate.normalizeConcurrency(asyncPolicy.concurrency, invocation.session ~= nil),
		timeoutSeconds = AsyncGate.normalizeTimeout(asyncPolicy.timeoutSeconds),
		system = systemName(invocation.system),
		action = invocation.action,
		actor = invocation.actor,
		remote = invocation.remote,
		diagnostics = invocation.diagnostics,
		onStarted = onStarted,
	}, execute)
end

local function runAction(invocation: Invocation, cancelToken: any): any
	local handler = invocation.handler
	return invocation.system:runAction(invocation.action, {
		actor = invocation.actor,
		payload = invocation.payload,
		context = invocation.context,
		diagnostics = invocation.diagnostics,
		session = invocation.session,
		states = invocation.states,
		expectedRevision = invocation.expectedRevision,
		remote = invocation.remote,
		cancelToken = cancelToken,
	}, function(scope: any): any
		return handler(scope, invocation.handlerRequest or invocation)
	end)
end

function ActionInvoker.run(invocation: Invocation): any
	assertName("Action name", invocation.action)
	if invocation.system == nil or type(invocation.system.runAction) ~= "function" then
		error("ActionInvoker.run expects a system contract", 2)
	end
	if type(invocation.handler) ~= "function" then
		error("ActionInvoker.run expects an action handler function", 2)
	end

	local asyncPolicy = invocation.asyncPolicy
	local function run(onStarted: any): any
		if asyncPolicy ~= nil then
			return runWithAsyncGate(invocation, asyncPolicy, function(cancelToken: any): any
				return runAction(invocation, cancelToken)
			end, onStarted)
		end

		onStarted()
		return runAction(invocation, nil)
	end

	local pipeline = invocation.pipeline
	if pipeline ~= nil then
		local pipelineFn: any = pipeline
		return pipelineFn({
			action = invocation.action,
			actor = invocation.actor,
			payload = invocation.payload,
			remote = invocation.remote,
			validated = invocation.validated == true,
			diagnostics = invocation.diagnostics,
		}, run)
	end

	return run(function() end)
end

return ActionInvoker
