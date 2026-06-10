local AsyncGate = require("../Core/AsyncGate")
local RateLimiter = require("../Core/RateLimiter")
local Schema = require("../Core/Schema")
local TaskScheduler = require("./TaskScheduler")

local RemoteGuard = {}

local function record(diagnostics, fields)
	if diagnostics and diagnostics.record then
		return diagnostics:record(fields)
	end
	return fields
end

local function copyMap(value)
	local copy = {}
	for key, child in pairs(value or {}) do
		copy[key] = child
	end
	return copy
end

local function hasServerEvent(remote)
	return remote and remote.OnServerEvent and remote.OnServerEvent.Connect
end

local function assertServerEvent(remote)
	if not hasServerEvent(remote) then
		error("RemoteGuard.connect expects a RemoteEvent-like value", 3)
	end
end

local function directionAllowsServer(direction)
	return direction == nil or direction == "server" or direction == "bidirectional"
end

local function assertServerDirection(remoteName, direction)
	if not directionAllowsServer(direction) then
		error("RemoteGuard.connect cannot attach a server handler to client remote " .. tostring(remoteName), 3)
	end
end

local function shouldUseRemoteFunction(remote, options, remoteOptions)
	local kind = options.kind or options.remoteKind
	if kind == "function" then
		return true
	end
	if kind == "event" then
		return false
	end
	if remoteOptions.response ~= nil or options.response ~= nil then
		return true
	end
	return remote and remote.OnServerInvoke ~= nil
end

local function connectServerFunction(remote, handler)
	local previous = remote.OnServerInvoke
	remote.OnServerInvoke = handler

	return {
		Disconnect = function()
			if remote.OnServerInvoke == handler then
				remote.OnServerInvoke = previous
			end
		end,
	}
end

local function actionContext(options, player, payload, remoteName)
	local context = copyMap(options.context)
	context.player = player
	context.actor = context.actor or player
	context.remote = remoteName
	context.payload = payload
	context.input = payload
	return context
end

local function remoteContext(options, player, payload, remoteName)
	local context = actionContext(options, player, payload, remoteName)
	context.remote = remoteName
	return context
end

local function recordLifecycleError(diagnostics, systemContract, name, message, player, remoteName)
	record(diagnostics, {
		level = "error",
		category = "lifecycle",
		system = systemContract:name(),
		name = name,
		message = message,
		context = {
			player = player,
			remote = remoteName,
		},
	})
end

local function callResolver(resolver, player, payload, remoteName, diagnostics, systemContract, diagnosticName)
	local ok, value = pcall(resolver, player, payload, remoteName)
	if ok then
		return value, true
	end

	recordLifecycleError(diagnostics, systemContract, diagnosticName, tostring(value), player, remoteName)
	return nil, false
end

local function sessionFromRegistry(options, sessionName, player, payload, remoteName, diagnostics, systemContract)
	local sessions = options.sessions or options.lifecycleSessions
	local resolver = sessions and sessions[sessionName]
	if resolver == nil then
		recordLifecycleError(
			diagnostics,
			systemContract,
			"LifecycleSessionMissing",
			"missing lifecycle session resolver: " .. tostring(sessionName),
			player,
			remoteName
		)
		return nil, false
	end
	if type(resolver) == "function" then
		return callResolver(resolver, player, payload, remoteName, diagnostics, systemContract, "LifecycleSessionError")
	end
	return resolver, true
end

local function lifecycleSession(options, remoteOptions, player, payload, remoteName, diagnostics, systemContract)
	if type(options.sessionFor) == "function" then
		return callResolver(options.sessionFor, player, payload, remoteName, diagnostics, systemContract, "LifecycleSessionError")
	end
	if options.session ~= nil then
		return options.session, true
	end

	local lifecycle = remoteOptions.lifecycle or {}
	if lifecycle.session ~= nil then
		return sessionFromRegistry(options, lifecycle.session, player, payload, remoteName, diagnostics, systemContract)
	end

	return nil, true
end

local function fieldPathValue(source, path)
	if type(path) ~= "string" or path == "" then
		return nil
	end

	local value = source
	for key in string.gmatch(path, "[^%.]+") do
		if type(value) ~= "table" then
			return nil
		end
		value = value[key]
	end
	return value
end

local function expectedRevision(options, remoteOptions, player, payload, remoteName, diagnostics, systemContract)
	local revision = options.expectedRevision or options.revision
	local policyRevision = remoteOptions.lifecycle and remoteOptions.lifecycle.revision
	if revision == nil then
		revision = policyRevision
	end

	if type(revision) == "function" then
		return callResolver(revision, player, payload, remoteName, diagnostics, systemContract, "LifecycleRevisionError")
	end
	if type(revision) == "string" then
		local value = fieldPathValue(payload, revision)
		if value == nil and policyRevision ~= nil then
			recordLifecycleError(
				diagnostics,
				systemContract,
				"LifecycleRevisionMissing",
				"missing lifecycle revision field: " .. revision,
				player,
				remoteName
			)
			return nil, false
		end
		return value, true
	end
	return revision, true
end

local function rateLimitKey(rateLimit, player, payload, remoteName)
	local key = rateLimit and rateLimit.key
	if type(key) == "function" then
		local ok, value = pcall(key, player, payload, remoteName)
		if ok and value ~= nil then
			return value
		end
		return player or "__anonymous"
	end
	if key == "global" then
		return "__global"
	end
	if key == "remote" then
		return remoteName
	end
	if type(key) == "string" and string.sub(key, 1, 8) == "payload." then
		return fieldPathValue(payload, string.sub(key, 9)) or player or "__anonymous"
	end
	return player or "__anonymous"
end

local function checkRateLimit(limiter, rateLimit, player, payload, remoteName, diagnostics, systemContract)
	if limiter == nil then
		return true
	end

	local key = rateLimitKey(rateLimit, player, payload, remoteName)
	if limiter:check(key, remoteName, rateLimit) then
		return true
	end

	record(diagnostics, {
		level = "error",
		category = "remote",
		system = systemContract:name(),
		name = "RemoteRateLimited",
		message = "remote rate limit exceeded: " .. tostring(remoteName),
		context = {
			player = player,
			remote = remoteName,
			key = key,
		},
	})
	return false
end

local function validateActionPayload(systemContract, actionName, remoteName, payload, diagnostics, context)
	local actionOptions = systemContract.actionOptions and systemContract:actionOptions(actionName) or nil
	if actionOptions ~= nil and actionOptions.input ~= nil then
		return systemContract:validateActionInput(actionName, payload, diagnostics, context)
	end
	return systemContract:validateRemote(remoteName, payload, diagnostics, context)
end

local function validateResponse(systemContract, remoteName, responseSchema, value, diagnostics, context)
	if responseSchema == nil and not systemContract.validateRemoteResponse then
		return value
	end

	context.result = value
	local response = nil
	if responseSchema ~= nil then
		response = Schema.validate(responseSchema, value, "response")
		if not response.ok then
			record(diagnostics, {
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

local function checkRemoteActor(systemContract, remoteName, player, context, diagnostics)
	if not systemContract.checkRemoteActor then
		return true
	end
	local result = systemContract:checkRemoteActor(remoteName, player, context, diagnostics)
	return result.ok == true
end

local function resolveAsyncPolicy(systemContract, actionName): any
	if actionName == nil or type(systemContract.actionOptions) ~= "function" then
		return nil
	end

	local actionOptions: any = systemContract:actionOptions(actionName)
	if actionOptions == nil then
		return nil
	end
	return actionOptions.async
end

local function resolveAsyncGate(options, asyncPolicy, actionName): any
	if asyncPolicy == nil then
		return nil
	end
	if options.asyncGate ~= nil then
		return options.asyncGate
	end

	local scheduler = options.scheduler or TaskScheduler.default()
	if scheduler == nil then
		error(
			"RemoteGuard.connect binds async action " .. tostring(actionName)
				.. " and needs options.asyncGate or options.scheduler",
			4
		)
	end
	return AsyncGate.new({
		scheduler = scheduler,
	})
end

local function runActionRemote(systemContract, remoteName, remoteOptions, handler, options, player, payload, diagnostics, asyncGate, asyncPolicy)
	local context = remoteContext(options, player, payload, remoteName)
	local validation = validateActionPayload(systemContract, remoteOptions.action, remoteName, payload, diagnostics, context)
	if not validation.ok then
		return nil
	end

	payload = validation.value
	context.payload = payload
	context.input = payload

	if not checkRemoteActor(systemContract, remoteName, player, context, diagnostics) then
		return nil
	end

	local session, sessionOk = lifecycleSession(options, remoteOptions, player, payload, remoteName, diagnostics, systemContract)
	if not sessionOk then
		return nil
	end

	local revision, revisionOk = expectedRevision(options, remoteOptions, player, payload, remoteName, diagnostics, systemContract)
	if not revisionOk then
		return nil
	end

	local function execute(cancelToken)
		return systemContract:runAction(remoteOptions.action, {
			actor = player,
			payload = payload,
			diagnostics = diagnostics,
			states = options.states,
			session = session,
			expectedRevision = revision,
			context = actionContext(options, player, payload, remoteName),
			cancelToken = cancelToken,
		}, function(scope)
			return handler(player, scope:payload(), scope)
		end)
	end

	local actionResult: any
	if asyncPolicy ~= nil and asyncGate ~= nil then
		local key: any = session
		if key == nil then
			key = player
		end
		if key == nil then
			key = remoteName
		end

		local gate: any = options.asyncGate
		actionResult = gate:run(key, {
			concurrency = AsyncGate.normalizeConcurrency(asyncPolicy.concurrency, session ~= nil),
			timeoutSeconds = AsyncGate.normalizeTimeout(asyncPolicy.timeoutSeconds),
			system = systemContract:name(),
			action = remoteOptions.action,
			remote = remoteName,
			diagnostics = diagnostics,
		}, execute)
	else
		actionResult = execute(nil)
	end

	if not actionResult.ok then
		return nil
	end

	return validateResponse(systemContract, remoteName, remoteOptions.response, actionResult.value, diagnostics, context)
end

local function runLegacyRemote(systemContract, remoteName, remoteOptions, handler, options, player, payload, diagnostics)
	local context = remoteContext(options, player, payload, remoteName)
	local validation = systemContract:validateRemote(remoteName, payload, diagnostics, context)
	if not validation.ok then
		return nil
	end

	payload = validation.value
	context.payload = payload
	context.input = payload

	if not checkRemoteActor(systemContract, remoteName, player, context, diagnostics) then
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
		record(diagnostics, {
			level = "error",
			category = "remote",
			system = systemContract:name(),
			name = "RemoteHandlerError",
			message = tostring(result),
			context = context,
		})
		return nil
	end

	return validateResponse(systemContract, remoteName, remoteOptions.response, result, diagnostics, context)
end

function RemoteGuard.connect(systemContract, remoteName, remote, handler, options)
	options = options or {}

	if not systemContract or not systemContract.validateRemote then
		error("RemoteGuard.connect expects a system contract", 2)
	end
	if type(handler) ~= "function" then
		error("RemoteGuard.connect expects a handler function", 2)
	end

	local diagnostics = options.diagnostics
	local remoteOptions = systemContract:remoteOptions(remoteName) or {}
	remoteOptions.action = options.action or remoteOptions.action
	remoteOptions.direction = options.direction or remoteOptions.direction or "server"
	remoteOptions.response = options.response or remoteOptions.response
	remoteOptions.rateLimit = options.rateLimit or remoteOptions.rateLimit
	remoteOptions.lifecycle = options.lifecycle or remoteOptions.lifecycle or {}

	local asyncPolicy = resolveAsyncPolicy(systemContract, remoteOptions.action)
	local asyncGate = resolveAsyncGate(options, asyncPolicy, remoteOptions.action)

	assertServerDirection(remoteName, remoteOptions.direction)

	local limiter = remoteOptions.rateLimit and RateLimiter.new(remoteOptions.rateLimit, options.clock) or nil
	local function handleServerCall(player, payload)
		if not checkRateLimit(limiter, remoteOptions.rateLimit, player, payload, remoteName, diagnostics, systemContract) then
			return nil
		end

		if remoteOptions.action and systemContract.runAction then
			return runActionRemote(systemContract, remoteName, remoteOptions, handler, options, player, payload, diagnostics, asyncGate, asyncPolicy)
		end
		return runLegacyRemote(systemContract, remoteName, remoteOptions, handler, options, player, payload, diagnostics)
	end

	if shouldUseRemoteFunction(remote, options, remoteOptions) then
		return connectServerFunction(remote, handleServerCall)
	end

	assertServerEvent(remote)
	return remote.OnServerEvent:Connect(function(player, payload) -- contracts-scan: ignore raw-remote-handler
		return handleServerCall(player, payload)
	end)
end

return RemoteGuard
