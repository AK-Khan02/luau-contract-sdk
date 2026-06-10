--!strict

local AsyncGate = require("./AsyncGate")
local Diagnostics = require("./Diagnostics")
local RemoteGuard = require("../Roblox/RemoteGuard")
local TaskScheduler = require("../Roblox/TaskScheduler")

export type Request = {
	actor: any?,
	player: any?,
	payload: any?,
	input: any?,
	context: any?,
	diagnostics: any?,
	session: any?,
	sessionName: string?,
	states: any?,
	expectedRevision: any?,
	revision: any?,
	remote: string?,
}

export type Config = {
	diagnostics: any?,
	sessions: any?,
	lifecycleSessions: any?,
	scheduler: any?,
}

local Runtime: any = {}
Runtime.__index = Runtime

local function assertName(kind: string, value: any)
	if type(value) ~= "string" or value == "" then
		error(kind .. " must be a non-empty string", 3)
	end
end

local function copyMap(value: any): any
	local copy = {}
	for key, child in pairs(value or {}) do
		copy[key] = child
	end
	return copy
end

local function sortedKeys(values: any): {string}
	local keys = {}
	for key in pairs(values or {}) do
		if type(key) == "string" then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	return keys
end

local function fieldPathValue(source: any, path: any): any
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

local function disconnect(connection: any)
	if connection and type(connection.Disconnect) == "function" then
		local target: any = connection
		target:Disconnect()
	end
end

local function record(diagnostics: any, fields: any): any
	if diagnostics and diagnostics.record then
		local target: any = diagnostics
		return target:record(fields)
	end
	return fields
end

local function isSystemContract(value: any): boolean
	return value ~= nil
		and type(value.name) == "function"
		and type(value.describe) == "function"
		and type(value.hasAction) == "function"
		and type(value.runAction) == "function"
		and type(value.remoteOptions) == "function"
		and type(value.actionForRemote) == "function"
end

function Runtime.new(systemContract: any, config: Config?): any
	if not isSystemContract(systemContract) then
		error("Runtime.new expects a system contract", 2)
	end

	local options: any = config or {}
	local runtime = setmetatable({
		_system = systemContract,
		_diagnostics = options.diagnostics or Diagnostics.new(),
		_handlers = {},
		_sessions = {},
		_connections = {},
		_boundRemotes = {},
		_scheduler = options.scheduler,
		_asyncGate = nil,
		_destroyed = false,
	}, Runtime)

	for name, resolver in pairs(options.sessions or options.lifecycleSessions or {}) do
		runtime:session(name, resolver)
	end

	return runtime
end

function Runtime._assertOpen(self: any)
	if self._destroyed then
		error("Runtime has been destroyed", 3)
	end
end

function Runtime.system(self: any): any
	return self._system
end

function Runtime.diagnostics(self: any): any
	return self._diagnostics
end

function Runtime._gate(self: any): any
	if self._asyncGate ~= nil then
		return self._asyncGate
	end

	local scheduler = self._scheduler or TaskScheduler.default()
	if scheduler == nil then
		error("Runtime needs a scheduler for async actions; pass config.scheduler", 3)
	end

	self._asyncGate = AsyncGate.new({
		scheduler = scheduler,
	})
	return self._asyncGate
end

function Runtime._asyncPolicy(self: any, actionName: string): any
	local actionOptions = self._system:actionOptions(actionName)
	if actionOptions == nil then
		return nil
	end
	return actionOptions.async
end

function Runtime.session(self: any, name: string, resolverOrSession: any): any
	self:_assertOpen()
	assertName("Runtime session name", name)
	if resolverOrSession == nil then
		error("Runtime session resolver must not be nil", 2)
	end

	self._sessions[name] = resolverOrSession
	return self
end

function Runtime.implement(self: any, actionName: string, handler: (any, any?) -> any, options: any?): any
	self:_assertOpen()
	assertName("Action name", actionName)
	if type(handler) ~= "function" then
		error("Runtime.implement expects an action handler function", 2)
	end
	local system: any = self._system
	if not system:hasAction(actionName) then
		error("Cannot implement unknown action: " .. actionName, 2)
	end
	local implementOptions: any = options or {}
	local handlers: any = self._handlers
	if handlers[actionName] ~= nil and not (implementOptions.overwrite == true) then
		error("Runtime action already implemented: " .. actionName, 2)
	end

	handlers[actionName] = handler
	return self
end

function Runtime._context(self: any, request: any): any
	local context = copyMap(request.context)
	if request.remote ~= nil then
		context.remote = context.remote or request.remote
	end
	return context
end

function Runtime._normalizeRequest(self: any, actionName: string, request: any?): any
	local source: any = request or {}
	local actor = source.actor
	if actor == nil then
		actor = source.player
	end

	local payload = source.payload
	if payload == nil then
		payload = source.input
	end

	local expectedRevision = source.expectedRevision
	if expectedRevision == nil then
		expectedRevision = source.revision
	end
	if type(expectedRevision) == "string" then
		expectedRevision = fieldPathValue(payload, expectedRevision)
	end

	return {
		action = actionName,
		actor = actor,
		payload = payload,
		context = self:_context(source),
		diagnostics = source.diagnostics or self._diagnostics,
		session = source.session,
		sessionName = source.sessionName,
		states = source.states,
		expectedRevision = expectedRevision,
		remote = source.remote,
	}
end

function Runtime._failure(self: any, name: string, message: string, request: any): any
	local category = "runtime"
	if string.sub(name, 1, 9) == "Lifecycle" then
		category = "lifecycle"
	end

	record(request.diagnostics or self._diagnostics, {
		level = "error",
		category = category,
		system = self._system:name(),
		name = name,
		message = message,
		context = {
			action = request.action,
			remote = request.remote,
			session = request.sessionName,
		},
	})

	return {
		ok = false,
		name = name,
		reason = message,
		context = request.context,
	}
end

function Runtime._resolveSession(self: any, request: any): (any?, boolean, any?)
	if request.session ~= nil then
		return request.session, true, nil
	end
	if request.sessionName == nil then
		return nil, true, nil
	end

	local sessionName = request.sessionName :: string
	local resolver = self._sessions[sessionName]
	if resolver == nil then
		local message = "missing lifecycle session resolver: " .. sessionName
		return nil, false, self:_failure("LifecycleSessionMissing", message, request)
	end
	if type(resolver) ~= "function" then
		return resolver, true, nil
	end

	local resolveSession: any = resolver
	local ok, sessionOrReason = pcall(resolveSession, request)
	if not ok then
		return nil, false, self:_failure("LifecycleSessionError", tostring(sessionOrReason), request)
	end
	if sessionOrReason == nil then
		local message = "lifecycle session resolver returned nil: " .. sessionName
		return nil, false, self:_failure("LifecycleSessionMissing", message, request)
	end

	return sessionOrReason, true, nil
end

function Runtime.invoke(self: any, actionName: string, request: Request?): any
	self:_assertOpen()
	assertName("Action name", actionName)

	local handler = self._handlers[actionName]
	if handler == nil then
		error("Runtime action is not implemented: " .. actionName, 2)
	end
	local actionHandler: any = handler

	local runtimeRequest = self:_normalizeRequest(actionName, request)
	local session, ok, failure = self:_resolveSession(runtimeRequest)
	if not ok then
		return failure
	end

	local function execute(cancelToken: any): any
		return self._system:runAction(actionName, {
			actor = runtimeRequest.actor,
			payload = runtimeRequest.payload,
			context = runtimeRequest.context,
			diagnostics = runtimeRequest.diagnostics,
			session = session,
			states = runtimeRequest.states,
			expectedRevision = runtimeRequest.expectedRevision,
			remote = runtimeRequest.remote,
			cancelToken = cancelToken,
		}, function(scope)
			return actionHandler(scope, runtimeRequest)
		end)
	end

	local asyncPolicy = self:_asyncPolicy(actionName)
	if asyncPolicy == nil then
		return execute(nil)
	end

	local gate = self:_gate()
	local key = session
	if key == nil then
		key = runtimeRequest.actor
	end
	if key == nil then
		key = actionName
	end

	return gate:run(key, {
		concurrency = AsyncGate.normalizeConcurrency(asyncPolicy.concurrency, session ~= nil),
		timeoutSeconds = AsyncGate.normalizeTimeout(asyncPolicy.timeoutSeconds),
		system = self._system:name(),
		action = actionName,
		remote = runtimeRequest.remote,
		diagnostics = runtimeRequest.diagnostics,
	}, execute)
end

function Runtime._remoteRequest(self: any, remoteName: string, bindOptions: any, player: any, payload: any): any
	local actionName = self._system:actionForRemote(remoteName) or remoteName
	return self:_normalizeRequest(actionName, {
		actor = player,
		payload = payload,
		context = bindOptions.context,
		diagnostics = bindOptions.diagnostics or self._diagnostics,
		remote = remoteName,
	})
end

function Runtime._remoteSessions(self: any, bindOptions: any): any
	local runtime = self
	local localSessions: any = bindOptions.sessions or bindOptions.lifecycleSessions or {}
	local sessions: any = {}

	return setmetatable(sessions, {
		__index = function(_, sessionName: any): any
			if localSessions[sessionName] == nil and runtime._sessions[sessionName] == nil then
				return nil
			end

			return function(player: any, payload: any, remoteName: string): any
				local request = runtime:_remoteRequest(remoteName, bindOptions, player, payload)
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

function Runtime._remoteRevision(self: any, bindOptions: any): any
	local revision = bindOptions.expectedRevision or bindOptions.revision
	if type(revision) ~= "function" then
		return revision
	end

	local runtime = self
	local revisionResolver: any = revision
	return function(player: any, payload: any, remoteName: string): any
		return revisionResolver(runtime:_remoteRequest(remoteName, bindOptions, player, payload))
	end
end

function Runtime._remoteHandler(self: any, remoteName: string, bindOptions: any): any
	local remoteOptions = self._system:remoteOptions(remoteName)
	if remoteOptions == nil then
		error("Cannot bind unknown remote: " .. remoteName, 3)
	end

	local actionName = remoteOptions.action
	if actionName ~= nil then
		local handler = self._handlers[actionName]
		if handler == nil then
			error("Cannot bind remote without implementation for action: " .. actionName, 3)
		end
		local actionHandler: any = handler

		return function(player: any, payload: any, scope: any): any
			local request = self:_remoteRequest(remoteName, bindOptions, player, payload)
			return actionHandler(scope, request)
		end
	end

	if type(bindOptions.handler) ~= "function" then
		error("Runtime.bindRemote needs options.handler for remotes without an action", 3)
	end
	return bindOptions.handler
end

function Runtime._remoteGuardOptions(self: any, bindOptions: any): any
	local options = copyMap(bindOptions)
	options.handler = nil
	options.diagnostics = bindOptions.diagnostics or self._diagnostics
	options.sessions = self:_remoteSessions(bindOptions)
	options.expectedRevision = self:_remoteRevision(bindOptions)
	options.revision = nil

	return options
end

function Runtime.bindRemote(self: any, remoteName: string, remoteObject: any, options: any?): any
	self:_assertOpen()
	assertName("Remote name", remoteName)
	if remoteObject == nil then
		error("Runtime.bindRemote expects a remote object", 2)
	end

	local bindOptions = options or {}
	if self._connections[remoteName] ~= nil then
		if bindOptions.overwrite ~= true then
			error("Runtime remote already bound: " .. remoteName, 2)
		end
		disconnect(self._connections[remoteName])
	end

	local handler = self:_remoteHandler(remoteName, bindOptions)
	local guardOptions: any = self:_remoteGuardOptions(bindOptions)

	local remoteOptions: any = self._system:remoteOptions(remoteName)
	local remoteAction: any = remoteOptions and remoteOptions.action
	if remoteAction ~= nil and self:_asyncPolicy(remoteAction) ~= nil then
		guardOptions.asyncGate = self:_gate()
	end

	local guardHandler: any = handler
	local connection = RemoteGuard.connect(self._system, remoteName, remoteObject, guardHandler, guardOptions)

	self._connections[remoteName] = connection
	self._boundRemotes[remoteName] = true
	return connection
end

function Runtime.bindRemotes(self: any, remoteMap: any, options: any?): any
	self:_assertOpen()
	if type(remoteMap) ~= "table" then
		error("Runtime.bindRemotes expects a map of remotes", 2)
	end

	for remoteName, remoteObject in pairs(remoteMap) do
		if type(remoteName) == "string" then
			self:bindRemote(remoteName, remoteObject, options)
		end
	end
	return self
end

function Runtime.describe(self: any): any
	return {
		system = self._system:describe(),
		implementedActions = sortedKeys(self._handlers),
		boundRemotes = sortedKeys(self._boundRemotes),
		sessions = sortedKeys(self._sessions),
		destroyed = self._destroyed,
	}
end

function Runtime.destroy(self: any): any
	if self._destroyed then
		return self
	end

	for _, connection in pairs(self._connections) do
		disconnect(connection)
	end

	if self._asyncGate ~= nil then
		local gate: any = self._asyncGate
		gate:destroy()
		self._asyncGate = nil
	end

	self._connections = {}
	self._boundRemotes = {}
	self._destroyed = true
	return self
end

return Runtime
