--!strict

local Names = require("./Names")
local TableUtil = require("./TableUtil")
local RemoteGuard = require("../Roblox/RemoteGuard")

local RuntimeRemoteBinding = {}

local assertName = Names.assertName
local copyMap = TableUtil.copyMap

local function disconnect(connection: any)
	if connection and type(connection.Disconnect) == "function" then
		local target: any = connection
		target:Disconnect()
	end
end

local function remoteRequest(runtime: any, remoteName: string, bindOptions: any, player: any, payload: any): any
	local actionName = runtime._system:actionForRemote(remoteName) or remoteName
	return runtime:_normalizeRequest(actionName, {
		actor = player,
		payload = payload,
		context = bindOptions.context,
		diagnostics = bindOptions.diagnostics or runtime._diagnostics,
		remote = remoteName,
	})
end

-- Builds the lazy session registry handed to RemoteGuard as options.sessions.
-- The per-session resolver below may raise or return nil; that is intentional and
-- safe because RemoteGuardLifecycle.callResolver pcall-wraps every invocation and
-- records a LifecycleSessionError, so a faulty resolver rejects the remote call
-- rather than crashing the handler. Regression: tests/suites/runtime.lua
-- ("throwing session resolver ...").
local function remoteSessions(runtime: any, bindOptions: any): any
	local localSessions: any = bindOptions.sessions or bindOptions.lifecycleSessions or {}
	local sessions: any = {}

	return setmetatable(sessions, {
		__index = function(_, sessionName: any): any
			if localSessions[sessionName] == nil and runtime._sessions[sessionName] == nil then
				return nil
			end

			return function(player: any, payload: any, remoteName: string): any
				local request = remoteRequest(runtime, remoteName, bindOptions, player, payload)
				request.sessionName = sessionName

				local resolver = localSessions[sessionName] or runtime._sessions[sessionName]
				if type(resolver) == "function" then
					local resolveSession: any = resolver
					local session = resolveSession(request)
					if session == nil then
						error("lifecycle session resolver returned nil: " .. tostring(sessionName))
					end
					return session
				end
				return resolver
			end
		end,
	})
end

local function remoteRevision(runtime: any, bindOptions: any): any
	local revision = bindOptions.expectedRevision or bindOptions.revision
	if type(revision) ~= "function" then
		return revision
	end

	local revisionResolver: any = revision
	return function(player: any, payload: any, remoteName: string): any
		return revisionResolver(remoteRequest(runtime, remoteName, bindOptions, player, payload))
	end
end

local function remoteHandler(runtime: any, remoteName: string, bindOptions: any): any
	local remoteOptions = runtime._system:remoteOptions(remoteName)
	if remoteOptions == nil then
		error("Cannot bind unknown remote: " .. remoteName, 3)
	end

	local actionName = remoteOptions.action
	if actionName ~= nil then
		local handler = runtime._handlers[actionName]
		if handler == nil then
			error("Cannot bind remote without implementation for action: " .. actionName, 3)
		end
		local actionHandler: any = handler

		return function(player: any, payload: any, scope: any): any
			local request = remoteRequest(runtime, remoteName, bindOptions, player, payload)
			return actionHandler(scope, request)
		end
	end

	if type(bindOptions.handler) ~= "function" then
		error("Runtime.bindRemote needs options.handler for remotes without an action", 3)
	end
	return bindOptions.handler
end

local function remoteGuardOptions(runtime: any, bindOptions: any): any
	local options = copyMap(bindOptions)
	options.handler = nil
	options.diagnostics = bindOptions.diagnostics or runtime._diagnostics
	options.sessions = remoteSessions(runtime, bindOptions)
	options.expectedRevision = remoteRevision(runtime, bindOptions)
	options.revision = nil

	return options
end

function RuntimeRemoteBinding.bind(runtime: any, remoteName: string, remoteObject: any, options: any?): any
	runtime:_assertOpen()
	assertName("Remote name", remoteName)
	if remoteObject == nil then
		error("Runtime.bindRemote expects a remote object", 2)
	end

	local bindOptions = options or {}
	if runtime._connections[remoteName] ~= nil then
		if bindOptions.overwrite ~= true then
			error("Runtime remote already bound: " .. remoteName, 2)
		end
		disconnect(runtime._connections[remoteName])
	end

	local handler = remoteHandler(runtime, remoteName, bindOptions)
	local guardOptions: any = remoteGuardOptions(runtime, bindOptions)

	local remoteOptions: any = runtime._system:remoteOptions(remoteName)
	local remoteAction: any = remoteOptions and remoteOptions.action
	if remoteAction ~= nil and runtime:_asyncPolicy(remoteAction) ~= nil then
		guardOptions.asyncGate = runtime:_gate()
	end
	guardOptions.pipeline = function(info: any, run: any): any
		return runtime:_runPipeline(info, run)
	end

	local guardHandler: any = handler
	local connection = RemoteGuard.connect(runtime._system, remoteName, remoteObject, guardHandler, guardOptions)

	runtime._connections[remoteName] = connection
	runtime._boundRemotes[remoteName] = true
	return connection
end

return RuntimeRemoteBinding
