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
