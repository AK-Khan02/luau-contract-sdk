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
			scheduler = config.scheduler,
		}),
		_diagnostics = diagnostics,
		_scheduler = config.scheduler,
		_remotes = {},
		_handlerCalls = {},
		_pendingThreads = {},
		_defaultResponses = config.defaultResponses or {},
	}, RemoteHarness)
end

function RemoteHarness._requireScheduler(self: any): any
	if self._scheduler == nil then
		error("RemoteHarness needs options.scheduler for async helpers; pass Contracts.Test.manualScheduler()", 3)
	end
	return self._scheduler
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

function RemoteHarness.implementYielding(self: any, actionName: string, handler: (((any, any) -> any))?): any
	self:_requireScheduler()
	local pending = self._pendingThreads
	local defaultResponses = self._defaultResponses
	local handlerFunction = handler
	return self:implement(actionName, function(scope: any, request: any)
		local queue = pending[actionName]
		if queue == nil then
			queue = {}
			pending[actionName] = queue
		end
		table.insert(queue, coroutine.running())
		coroutine.yield()

		if handlerFunction ~= nil then
			return handlerFunction(scope, request)
		end
		return defaultHandlerResult(defaultResponses, actionName)
	end)
end

function RemoteHarness.pendingHandlerCount(self: any, actionName: string): number
	local queue = self._pendingThreads[actionName]
	if queue == nil then
		return 0
	end
	return #queue
end

function RemoteHarness.resume(self: any, actionName: string): boolean
	local scheduler = self:_requireScheduler()
	local queue = self._pendingThreads[actionName]
	if queue == nil or #queue == 0 then
		return false
	end

	local thread = table.remove(queue, 1)
	local spawnFn = scheduler.spawn :: (any) -> any
	spawnFn(thread)
	return true
end

function RemoteHarness.callAsync(self: any, remoteName: string, player: any, payload: any): any
	local scheduler = self:_requireScheduler()
	local state = {
		settled = false,
		result = nil,
	}

	local spawnFn = scheduler.spawn :: (any) -> any
	spawnFn(function()
		state.result = self:call(remoteName, player, payload)
		state.settled = true
	end)

	return state
end

function RemoteHarness.advance(self: any, seconds: number)
	local scheduler = self:_requireScheduler()
	if type(scheduler.advance) ~= "function" then
		error("RemoteHarness.advance needs a scheduler with advance (use Contracts.Test.manualScheduler())", 2)
	end
	local advanceFn = scheduler.advance :: (number) -> ()
	advanceFn(seconds)
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
