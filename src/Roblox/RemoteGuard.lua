local RateLimiter = require("../Core/RateLimiter")

local RemoteGuard = {}

local function record(diagnostics, fields)
	if diagnostics and diagnostics.record then
		return diagnostics:record(fields)
	end
	return fields
end

local function assertRemoteEvent(remoteEvent)
	if not remoteEvent or not remoteEvent.OnServerEvent or not remoteEvent.OnServerEvent.Connect then
		error("RemoteGuard.connect expects a RemoteEvent-like value", 3)
	end
end

local function actionContext(options, player, remoteName)
	local context = {}
	for key, value in pairs(options.context or {}) do
		context[key] = value
	end
	context.player = player
	context.remote = remoteName
	return context
end

local function lifecycleSession(options, player, payload, remoteName, diagnostics, systemContract)
	if type(options.sessionFor) == "function" then
		local ok, sessionOrReason = pcall(options.sessionFor, player, payload, remoteName)
		if ok then
			return sessionOrReason
		end

		record(diagnostics, {
			level = "error",
			category = "lifecycle",
			system = systemContract:name(),
			name = "LifecycleSessionError",
			message = tostring(sessionOrReason),
			context = {
				player = player,
				remote = remoteName,
			},
		})
		return nil
	end

	return options.session
end

local function expectedRevision(options, player, payload, remoteName, diagnostics, systemContract)
	local revision = options.expectedRevision or options.revision
	if type(revision) == "function" then
		local ok, value = pcall(revision, player, payload, remoteName)
		if ok then
			return value, true
		end

		record(diagnostics, {
			level = "error",
			category = "lifecycle",
			system = systemContract:name(),
			name = "LifecycleRevisionError",
			message = tostring(value),
			context = {
				player = player,
				remote = remoteName,
			},
		})
		return nil, false
	end
	return revision, true
end

function RemoteGuard.connect(systemContract, remoteName, remoteEvent, handler, options)
	options = options or {}

	if not systemContract or not systemContract.validateRemote then
		error("RemoteGuard.connect expects a system contract", 2)
	end
	if type(handler) ~= "function" then
		error("RemoteGuard.connect expects a handler function", 2)
	end
	assertRemoteEvent(remoteEvent)

	local diagnostics = options.diagnostics
	local remoteOptions = systemContract:remoteOptions(remoteName) or {}
	local actionName = options.action or remoteOptions.action
	local rateLimit = options.rateLimit or remoteOptions.rateLimit
	local limiter = rateLimit and RateLimiter.new(rateLimit, options.clock) or nil

	return remoteEvent.OnServerEvent:Connect(function(player, payload) -- contracts-scan: ignore raw-remote-handler
		if limiter and not limiter:check(player, remoteName, rateLimit) then
			record(diagnostics, {
				level = "error",
				category = "remote",
				system = systemContract:name(),
				name = "RemoteRateLimited",
				message = "remote rate limit exceeded: " .. tostring(remoteName),
				context = {
					player = player,
					remote = remoteName,
				},
			})
			return nil
		end

		if actionName and systemContract.runAction then
			local actionOptions = systemContract.actionOptions and systemContract:actionOptions(actionName) or nil
			if actionOptions ~= nil and actionOptions.input == nil then
				local remoteValidation = systemContract:validateRemote(remoteName, payload, diagnostics, {
					player = player,
					remote = remoteName,
				})
				if not remoteValidation.ok then
					return nil
				end
				payload = remoteValidation.value
			end

			local revision, revisionOk = expectedRevision(options, player, payload, remoteName, diagnostics, systemContract)
			if revisionOk == false then
				return nil
			end

			local actionResult = systemContract:runAction(actionName, {
				actor = player,
				payload = payload,
				diagnostics = diagnostics,
				states = options.states,
				session = lifecycleSession(options, player, payload, remoteName, diagnostics, systemContract),
				expectedRevision = revision,
				context = actionContext(options, player, remoteName),
			}, function(scope)
				return handler(player, scope:payload(), scope)
			end)

			if not actionResult.ok then
				return nil
			end

			return actionResult.value
		end

		local validation = systemContract:validateRemote(remoteName, payload, diagnostics, {
			player = player,
			remote = remoteName,
		})
		if not validation.ok then
			return nil
		end

		local ok, result = pcall(handler, player, validation.value, {
			player = player,
			payload = validation.value,
			remote = remoteEvent,
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
				context = {
					player = player,
					remote = remoteName,
				},
			})
			return nil
		end

		return result
	end)
end

return RemoteGuard
