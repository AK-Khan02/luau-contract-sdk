--!strict

local ActionInvoker = require("../Core/ActionInvoker")
local Result = require("../Core/Result")
local TableUtil = require("../Core/TableUtil")
local RemoteGuardActionPolicy = require("./RemoteGuardActionPolicy")
local RemoteGuardLifecycle = require("./RemoteGuardLifecycle")
local RemoteGuardRateLimit = require("./RemoteGuardRateLimit")
local RemoteGuardTransport = require("./RemoteGuardTransport")

local RemoteGuard = {}

local copyMap = TableUtil.copyMap

local function actionContext(options: any, player: any, payload: any, remoteName: string): any
	local context = copyMap(options.context or {})
	context.player = player
	context.actor = context.actor or player
	context.remote = remoteName
	context.payload = payload
	context.input = payload
	return context
end

local function remoteContext(options: any, player: any, payload: any, remoteName: string): any
	local context = actionContext(options, player, payload, remoteName)
	context.remote = remoteName
	return context
end

local function effectiveRemoteOptions(systemContract: any, remoteName: string, options: any): any
	local remoteOptions = systemContract:remoteOptions(remoteName) or {}
	return {
		action = options.action or remoteOptions.action,
		direction = options.direction or remoteOptions.direction or "server",
		response = options.response or remoteOptions.response,
		rateLimit = options.rateLimit or remoteOptions.rateLimit,
		lifecycle = options.lifecycle or remoteOptions.lifecycle or {},
	}
end

local function runActionRemote(
	systemContract: any,
	remoteName: string,
	remoteOptions: any,
	handler: any,
	options: any,
	player: any,
	payload: any,
	diagnostics: any,
	asyncGate: any,
	asyncPolicy: any
): any
	local context = remoteContext(options, player, payload, remoteName)
	local validation = RemoteGuardActionPolicy.validateActionPayload(
		systemContract,
		remoteOptions.action,
		remoteName,
		payload,
		diagnostics,
		context
	)
	if not validation.ok then
		return nil
	end

	payload = validation.value
	context.payload = payload
	context.input = payload

	if not RemoteGuardActionPolicy.checkRemoteActor(systemContract, remoteName, player, context, diagnostics) then
		return nil
	end

	local session, sessionOk = RemoteGuardLifecycle.resolveSession(
		options,
		remoteOptions,
		player,
		payload,
		remoteName,
		diagnostics,
		systemContract
	)
	if not sessionOk then
		return nil
	end

	local revision, revisionOk = RemoteGuardLifecycle.expectedRevision(
		options,
		remoteOptions,
		player,
		payload,
		remoteName,
		diagnostics,
		systemContract
	)
	if not revisionOk then
		return nil
	end

	local actionResult = ActionInvoker.run({
		system = systemContract,
		action = remoteOptions.action,
		actor = player,
		payload = payload,
		diagnostics = diagnostics,
		states = options.states,
		session = session,
		expectedRevision = revision,
		context = actionContext(options, player, payload, remoteName),
		remote = remoteName,
		validated = true,
		handler = function(scope: any)
			return handler(player, scope:payload(), scope)
		end,
		asyncPolicy = asyncPolicy,
		asyncGate = asyncGate,
		asyncFallbackKey = remoteName,
		pipeline = options.pipeline,
	})

	if not actionResult.ok then
		return nil
	end

	return RemoteGuardActionPolicy.validateResponse(
		systemContract,
		remoteName,
		remoteOptions.response,
		actionResult.value,
		diagnostics,
		context
	)
end

local function runLegacyRemote(
	systemContract: any,
	remoteName: string,
	remoteOptions: any,
	handler: any,
	options: any,
	player: any,
	payload: any,
	diagnostics: any
): any
	local context = remoteContext(options, player, payload, remoteName)
	local validation = systemContract:validateRemote(remoteName, payload, diagnostics, context)
	if not validation.ok then
		return nil
	end

	payload = validation.value
	context.payload = payload
	context.input = payload

	if not RemoteGuardActionPolicy.checkRemoteActor(systemContract, remoteName, player, context, diagnostics) then
		return nil
	end

	local ok, result = pcall(handler, player, payload, {
		player = player,
		payload = payload,
		remote = remoteName,
		diagnostics = diagnostics,
		system = systemContract,
	})
	if not ok then
		Result.record(diagnostics, {
			level = "error",
			category = "remote",
			system = systemContract:name(),
			name = "RemoteHandlerError",
			message = tostring(result),
			context = context,
		})
		return nil
	end

	return RemoteGuardActionPolicy.validateResponse(
		systemContract,
		remoteName,
		remoteOptions.response,
		result,
		diagnostics,
		context
	)
end

function RemoteGuard.connect(systemContract: any, remoteName: string, remote: any, handler: any, options: any?): any
	options = options or {}

	if not systemContract or not systemContract.validateRemote then
		error("RemoteGuard.connect expects a system contract", 2)
	end
	if type(handler) ~= "function" then
		error("RemoteGuard.connect expects a handler function", 2)
	end

	local diagnostics = options.diagnostics
	local remoteOptions = effectiveRemoteOptions(systemContract, remoteName, options)
	RemoteGuardRateLimit.assertKey(remoteOptions.rateLimit, remoteName)

	local asyncPolicy = RemoteGuardActionPolicy.resolveAsyncPolicy(systemContract, remoteOptions.action)
	local asyncGate = RemoteGuardActionPolicy.resolveAsyncGate(options, asyncPolicy, remoteOptions.action)
	RemoteGuardTransport.assertServerDirection(remoteName, remoteOptions.direction)

	local limiter = RemoteGuardRateLimit.create(remoteOptions.rateLimit, options.clock)
	local function handleServerCall(player: any, payload: any): any
		if
			not RemoteGuardRateLimit.check(
				limiter,
				remoteOptions.rateLimit,
				player,
				payload,
				remoteName,
				diagnostics,
				systemContract
			)
		then
			return nil
		end

		if remoteOptions.action and systemContract.runAction then
			return runActionRemote(
				systemContract,
				remoteName,
				remoteOptions,
				handler,
				options,
				player,
				payload,
				diagnostics,
				asyncGate,
				asyncPolicy
			)
		end
		return runLegacyRemote(
			systemContract,
			remoteName,
			remoteOptions,
			handler,
			options,
			player,
			payload,
			diagnostics
		)
	end

	local evictionConnection = RemoteGuardRateLimit.connectPlayerEviction(limiter, options)
	local baseConnection
	if RemoteGuardTransport.shouldUseRemoteFunction(remote, options, remoteOptions) then
		baseConnection = RemoteGuardTransport.connectServerFunction(remote, handleServerCall)
	else
		RemoteGuardTransport.assertServerEvent(remote)
		-- Internal RemoteGuard.connect adapter; handleServerCall owns validation before user code.
		baseConnection = remote.OnServerEvent:Connect(
			function(player, payload) -- contracts-scan: ignore raw-remote-handler
				return handleServerCall(player, payload)
			end
		)
	end

	return RemoteGuardTransport.composeConnection(baseConnection, evictionConnection)
end

return RemoteGuard
