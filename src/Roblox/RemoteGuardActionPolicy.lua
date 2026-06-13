--!strict

local ActionInvoker = require("../Core/ActionInvoker")
local AsyncGate = require("../Core/AsyncGate")
local Result = require("../Core/Result")
local Schema = require("../Core/Schema")
local TaskScheduler = require("./TaskScheduler")

local RemoteGuardActionPolicy = {}

function RemoteGuardActionPolicy.validateActionPayload(
	systemContract: any,
	actionName: string,
	remoteName: string,
	payload: any,
	diagnostics: any,
	context: any
): any
	local actionOptions = nil
	if type(systemContract.actionOptions) == "function" then
		local actionOptionsFn = systemContract.actionOptions :: (any, string) -> any
		actionOptions = actionOptionsFn(systemContract, actionName)
	end
	if actionOptions ~= nil and actionOptions.input ~= nil then
		return systemContract:validateActionInput(actionName, payload, diagnostics, context)
	end
	return systemContract:validateRemote(remoteName, payload, diagnostics, context)
end

function RemoteGuardActionPolicy.validateResponse(
	systemContract: any,
	remoteName: string,
	responseSchema: any,
	value: any,
	diagnostics: any,
	context: any
): any
	if responseSchema == nil and not systemContract.validateRemoteResponse then
		return value
	end

	context.result = value
	local response = nil
	if responseSchema ~= nil then
		response = Schema.validate(responseSchema, value, "response")
		if not response.ok then
			Result.record(diagnostics, {
				level = "error",
				category = "remote",
				system = systemContract:name(),
				name = "RemoteResponseInvalid",
				message = response.reason,
				context = context,
			})
		end
	else
		response = systemContract:validateRemoteResponse(remoteName, value, diagnostics, context)
	end
	if not response.ok then
		return nil
	end
	return response.value
end

function RemoteGuardActionPolicy.checkRemoteActor(
	systemContract: any,
	remoteName: string,
	player: any,
	context: any,
	diagnostics: any
): boolean
	if not systemContract.checkRemoteActor then
		return true
	end
	local checkRemoteActorFn = systemContract.checkRemoteActor :: (any, string, any, any, any) -> any
	local result = checkRemoteActorFn(systemContract, remoteName, player, context, diagnostics)
	return result.ok == true
end

function RemoteGuardActionPolicy.resolveAsyncPolicy(systemContract: any, actionName: string?): any
	if actionName == nil then
		return nil
	end
	return ActionInvoker.asyncPolicy(systemContract, actionName)
end

function RemoteGuardActionPolicy.resolveAsyncGate(options: any, asyncPolicy: any, actionName: string?): any
	if asyncPolicy == nil then
		return nil
	end
	if options.asyncGate ~= nil then
		return options.asyncGate
	end

	local scheduler = options.scheduler or TaskScheduler.default()
	if scheduler == nil then
		error(
			"RemoteGuard.connect binds async action "
				.. tostring(actionName)
				.. " and needs options.asyncGate or options.scheduler",
			4
		)
	end
	return AsyncGate.new({
		scheduler = scheduler,
	})
end

return RemoteGuardActionPolicy
