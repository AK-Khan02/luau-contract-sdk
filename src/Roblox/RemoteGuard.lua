local AsyncGate = require("../Core/AsyncGate")
local PlayersService = require("./PlayersService")
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

-- Real Instances error on invalid member reads instead of returning nil, so
-- class checks must go through IsA. Returns nil when the remote has no IsA
-- (legacy table fakes), letting callers fall back to duck typing.
local function remoteClassCheck(remote, className)
	if remote == nil then
		return nil
	end
	local readable, isA = pcall(function()
		return remote.IsA
	end)
	if not readable or type(isA) ~= "function" then
		return nil
	end
	local ok, result = pcall(isA, remote, className)
	if not ok then
		return nil
	end
	return result == true
end

local function hasServerEvent(remote)
	local byClass = remoteClassCheck(remote, "BaseRemoteEvent")
	if byClass ~= nil then
		return byClass
	end
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
	local byClass = remoteClassCheck(remote, "RemoteFunction")
	if byClass ~= nil then
		return byClass
	end
	if remoteOptions.response ~= nil or options.response ~= nil then
		return true
	end
	return remote and remote.OnServerInvoke ~= nil
end

-- Per-player bucket key. Prefer a stable UserId so the key is a small scalar
-- that survives across the player's Instances and can be evicted on leave;
-- fall back to the player value, then a shared anonymous bucket.
local function playerBucketKey(player)
	if type(player) == "table" and player.UserId ~= nil then
		return player.UserId
	end
	return player or "__anonymous"
end

local function safeDisconnect(connection)
	if connection == nil then
		return
	end
	local disconnect = connection.Disconnect
	if type(disconnect) == "function" then
		disconnect(connection)
	end
end

local function composeConnection(base, extra)
	if extra == nil then
		return base
	end
	return {
		Disconnect = function()
			safeDisconnect(base)
			safeDisconnect(extra)
		end,
	}
end

local function resolvePlayersService(options)
	if options.playersService ~= nil then
		return options.playersService
	end
	-- Auto-resolve the live Players service so eviction works without wiring;
	-- the engine global lives in PlayersService (a --!nocheck module).
	return PlayersService.resolve()
end

-- Evict a player's rate-limit bucket when they leave so per-player keys cannot
-- accumulate for the lifetime of the server.
local function connectPlayerEviction(limiter, options)
	if limiter == nil then
		return nil
	end
	local players = resolvePlayersService(options)
	local removing = players and players.PlayerRemoving
	if removing == nil or type(removing.Connect) ~= "function" then
		return nil
	end
	return removing:Connect(function(player) -- contracts-scan: ignore raw-remote-handler
		limiter:removeKey(playerBucketKey(player))
	end)
end

local function connectServerFunction(remote, handler)
	-- OnServerInvoke is a write-only callback on real RemoteFunctions: reads
	-- throw, so the previous callback can only be captured (and restored) on
	-- fakes that allow reading it.
	local readable, previous = pcall(function()
		return remote.OnServerInvoke
	end)

	remote.OnServerInvoke = handler

	return {
		Disconnect = function()
			local ok, current = pcall(function()
				return remote.OnServerInvoke
			end)
			if ok and current ~= handler then
				return
			end
			if readable then
				remote.OnServerInvoke = previous
			else
				remote.OnServerInvoke = nil
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

-- Config-time guard: the bucket key is chosen BEFORE payload validation, so it
-- must never be derived from client-controlled payload — that would let a
-- client mint unlimited buckets (each with a fresh budget) to bypass the limit
-- and grow memory without bound.
local function assertRateLimitKey(rateLimit: any, remoteName: any)
	local key = rateLimit and rateLimit.key
	if key == nil or type(key) == "function" or key == "global" or key == "remote" then
		return
	end
	if type(key) == "string" and string.sub(key, 1, 8) == "payload." then
		error(
			"RemoteGuard rate limit for " .. tostring(remoteName)
				.. " cannot key on client payload (" .. key
				.. "); use the default actor key, \"global\", \"remote\", or a function",
			3
		)
	end
	error(
		"RemoteGuard rate limit for " .. tostring(remoteName)
			.. " has an invalid key " .. tostring(key)
			.. "; use the default actor key, \"global\", \"remote\", or a function",
		3
	)
end

local function rateLimitKey(rateLimit, player, payload, remoteName)
	local key = rateLimit and rateLimit.key
	if type(key) == "function" then
		local ok, value = pcall(key, player, payload, remoteName)
		if ok and value ~= nil then
			return value
		end
		return playerBucketKey(player)
	end
	if key == "global" then
		return "__global"
	end
	if key == "remote" then
		return remoteName
	end
	return playerBucketKey(player)
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

	local function run(onStarted: any): any
		if asyncPolicy ~= nil and asyncGate ~= nil then
			local key: any = session
			if key == nil then
				key = player
			end
			if key == nil then
				key = remoteName
			end

			local gate: any = asyncGate
			return gate:run(key, {
				concurrency = AsyncGate.normalizeConcurrency(asyncPolicy.concurrency, session ~= nil),
				timeoutSeconds = AsyncGate.normalizeTimeout(asyncPolicy.timeoutSeconds),
				system = systemContract:name(),
				action = remoteOptions.action,
				actor = player,
				remote = remoteName,
				diagnostics = diagnostics,
				onStarted = onStarted,
			}, execute)
		end

		onStarted()
		return execute(nil)
	end

	local actionResult: any
	local pipeline: any = options.pipeline
	if pipeline ~= nil then
		actionResult = pipeline({
			action = remoteOptions.action,
			actor = player,
			payload = payload,
			remote = remoteName,
			validated = true,
			diagnostics = diagnostics,
		}, run)
	else
		actionResult = run(function() end)
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

	assertRateLimitKey(remoteOptions.rateLimit, remoteName)

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

	local evictionConnection = connectPlayerEviction(limiter, options)

	local baseConnection
	if shouldUseRemoteFunction(remote, options, remoteOptions) then
		baseConnection = connectServerFunction(remote, handleServerCall)
	else
		assertServerEvent(remote)
		baseConnection = remote.OnServerEvent:Connect(function(player, payload) -- contracts-scan: ignore raw-remote-handler
			return handleServerCall(player, payload)
		end)
	end

	return composeConnection(baseConnection, evictionConnection)
end

return RemoteGuard
