--!strict

local Diagnostics = require("../Core/Diagnostics")
local Runtime = require("../Core/Runtime")

export type RemoteHarness = {
	contract: (RemoteHarness) -> any,
	runtime: (RemoteHarness) -> any,
	diagnostics: (RemoteHarness) -> any,
	implement: (RemoteHarness, string, (((any, any) -> any))?) -> RemoteHarness,
	bind: (RemoteHarness, string, any?) -> any,
	call: (RemoteHarness, string, any, any) -> any,
	clearDiagnostics: (RemoteHarness) -> (),
	lastDiagnostic: (RemoteHarness) -> any?,
	handlerCalls: (RemoteHarness, string) -> number,
	wasHandlerCalled: (RemoteHarness, string) -> boolean,
}

local RemoteHarness = {}
RemoteHarness.__index = RemoteHarness

local function copyMap(value: any): any
	local copy = {}
	for key, child in pairs(value or {}) do
		copy[key] = child
	end
	return copy
end

local function fakeEvent()
	local callback: ((any, any) -> any)? = nil
	local remote: any = {}
	local function connect(_, handler: (any, any) -> any)
		callback = handler
		return {
			Disconnect = function()
				if callback == handler then
					callback = nil
				end
			end,
		}
	end

	remote.OnServerEvent = {
		Connect = connect,
	}
	function remote:fireServer(player: any, payload: any)
		local handler = callback
		if handler ~= nil then
			return handler(player, payload)
		end
		return nil
	end
	return remote
end

local function fakeFunction()
	local remote: any = {
		OnServerInvoke = function() end,
	}
	function remote:invokeServer(player: any, payload: any)
		if type(self.OnServerInvoke) == "function" then
			return self.OnServerInvoke(player, payload)
		end
		return nil
	end
	return remote
end

local function remoteUsesFunction(systemContract: any, remoteName: string, options: any?): boolean
	if options and options.kind == "function" then
		return true
	end
	if options and options.kind == "event" then
		return false
	end
	local remoteOptions = systemContract:remoteOptions(remoteName) or {}
	return remoteOptions.response ~= nil
end

local function defaultHandlerResult(defaultResponses: any, actionName: string)
	local response = defaultResponses and defaultResponses[actionName]
	if type(response) == "function" then
		return response()
	end
	if response ~= nil then
		return response
	end
	return {}
end

function RemoteHarness.new(systemContract: any, options: any?): any
	local config = options or {}
	local diagnostics = config.diagnostics or Diagnostics.new()
	return setmetatable({
		_contract = systemContract,
		_runtime = config.runtime or Runtime.new(systemContract, {
			diagnostics = diagnostics,
			sessions = config.sessions,
		}),
		_diagnostics = diagnostics,
		_remotes = {},
		_handlerCalls = {},
		_defaultResponses = config.defaultResponses or {},
	}, RemoteHarness)
end

function RemoteHarness.contract(self: any): any
	return self._contract
end

function RemoteHarness.runtime(self: any): any
	return self._runtime
end

function RemoteHarness.diagnostics(self: any): any
	return self._diagnostics
end

function RemoteHarness.implement(self: any, actionName: string, handler: (((any, any) -> any))?): any
	local calls = self._handlerCalls
	local defaultResponses = self._defaultResponses
	local handlerFunction = handler
	self._runtime:implement(actionName, function(scope: any, request: any)
		calls[actionName] = (calls[actionName] or 0) + 1
		if handlerFunction ~= nil then
			return handlerFunction(scope, request)
		end
		return defaultHandlerResult(defaultResponses, actionName)
	end, {
		overwrite = true,
	})
	return self
end

function RemoteHarness.bind(self: any, remoteName: string, options: any?): any
	local bindOptions = copyMap(options or {})
	local remote = nil
	if remoteUsesFunction(self._contract, remoteName, bindOptions) then
		remote = fakeFunction()
	else
		remote = fakeEvent()
	end

	self._runtime:bindRemote(remoteName, remote, bindOptions)
	self._remotes[remoteName] = remote
	return remote
end

function RemoteHarness.call(self: any, remoteName: string, player: any, payload: any): any
	local remote: any = self._remotes[remoteName]
	if remote == nil then
		error("RemoteHarness remote is not bound: " .. tostring(remoteName), 2)
	end
	local invokeServer: any = remote.invokeServer
	if type(invokeServer) == "function" then
		local invoke = invokeServer :: (any, any, any) -> any
		return invoke(remote, player, payload)
	end
	return remote:fireServer(player, payload)
end

function RemoteHarness.clearDiagnostics(self: any)
	self._diagnostics:clear()
end

function RemoteHarness.lastDiagnostic(self: any): any?
	return self._diagnostics:last()
end

function RemoteHarness.handlerCalls(self: any, actionName: string): number
	return self._handlerCalls[actionName] or 0
end

function RemoteHarness.wasHandlerCalled(self: any, actionName: string): boolean
	return self:handlerCalls(actionName) > 0
end

return RemoteHarness
