--!strict

local RemoteGuardTransport = {}

-- Real Instances error on invalid member reads instead of returning nil, so
-- class checks must go through IsA. Returns nil when the remote has no IsA
-- (legacy table fakes), letting callers fall back to duck typing.
local function remoteClassCheck(remote: any, className: string): boolean?
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

local function hasServerEvent(remote: any): boolean
	local byClass = remoteClassCheck(remote, "BaseRemoteEvent")
	if byClass ~= nil then
		return byClass
	end
	if remote == nil then
		return false
	end
	local event: any = remote.OnServerEvent
	return event ~= nil and type(event.Connect) == "function"
end

local function directionAllowsServer(direction: any): boolean
	return direction == nil or direction == "server" or direction == "bidirectional"
end

local function safeDisconnect(connection: any)
	if connection == nil then
		return
	end
	local disconnect = connection.Disconnect
	if type(disconnect) == "function" then
		local disconnectFn = disconnect :: (any) -> ()
		disconnectFn(connection)
	end
end

function RemoteGuardTransport.assertServerEvent(remote: any)
	if not hasServerEvent(remote) then
		error("RemoteGuard.connect expects a RemoteEvent-like value", 3)
	end
end

function RemoteGuardTransport.assertServerDirection(remoteName: any, direction: any)
	if not directionAllowsServer(direction) then
		error("RemoteGuard.connect cannot attach a server handler to client remote " .. tostring(remoteName), 3)
	end
end

function RemoteGuardTransport.shouldUseRemoteFunction(remote: any, options: any, remoteOptions: any): boolean
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

function RemoteGuardTransport.connectServerFunction(remote: any, handler: any): any
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

function RemoteGuardTransport.composeConnection(base: any, extra: any): any
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

return RemoteGuardTransport
