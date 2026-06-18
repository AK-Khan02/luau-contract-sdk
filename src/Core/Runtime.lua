--!strict

local AsyncGate = require("./AsyncGate")
local ActionInvoker = require("./ActionInvoker")
local Diagnostics = require("./Diagnostics")
local Names = require("./Names")
local Result = require("./Result")
local RuntimePipeline = require("./RuntimePipeline")
local RuntimeRemoteBinding = require("./RuntimeRemoteBinding")
local RuntimeRequest = require("./RuntimeRequest")
local RuntimeTypes = require("./RuntimeTypes")
local TaskScheduler = require("../Roblox/TaskScheduler")

export type DiagnosticsSink = RuntimeTypes.DiagnosticsSink
export type Request = RuntimeTypes.Request
export type SessionResolver = RuntimeTypes.SessionResolver
export type SessionMap = RuntimeTypes.SessionMap
export type ActionHandler = RuntimeTypes.ActionHandler
export type TapHandlers = RuntimeTypes.TapHandlers
export type Middleware = RuntimeTypes.Middleware
export type UseOptions = RuntimeTypes.UseOptions
export type Config = RuntimeTypes.Config
type NormalizedRequest = RuntimeTypes.NormalizedRequest
type PipelineInfo = RuntimeTypes.PipelineInfo
type RuntimeData = RuntimeTypes.RuntimeData

local Runtime = {}
Runtime.__index = Runtime

export type Runtime = typeof(setmetatable({} :: RuntimeData, Runtime))

local assertName = Names.assertName
local sortedKeys = require("./TableUtil").sortedStringKeys

local function disconnect(connection: unknown)
	local target = connection :: any
	if target and type(target.Disconnect) == "function" then
		local disconnectFn = target.Disconnect :: (any) -> ()
		disconnectFn(target)
	end
end

local function systemName(systemContract: unknown): string
	local target = systemContract :: any
	if target ~= nil and type(target.name) == "function" then
		local nameFn = target.name :: (any) -> string
		return nameFn(target)
	end
	return "unknown"
end

local function isSystemContract(value: unknown): boolean
	local target = value :: any
	return target ~= nil
		and type(target.name) == "function"
		and type(target.describe) == "function"
		and type(target.hasAction) == "function"
		and type(target.runAction) == "function"
		and type(target.remoteOptions) == "function"
		and type(target.actionForRemote) == "function"
end

function Runtime.new(systemContract: unknown, config: Config?): Runtime
	if not isSystemContract(systemContract) then
		error("Runtime.new expects a system contract", 2)
	end

	local options: Config = config or {}
	local runtime = setmetatable(
		{
			_system = systemContract,
			_diagnostics = options.diagnostics or Diagnostics.new(),
			_handlers = {},
			_sessions = {},
			_connections = {},
			_boundRemotes = {},
			_scheduler = options.scheduler,
			_asyncGate = nil,
			_taps = {},
			_middleware = {},
			_destroyed = false,
		} :: RuntimeData,
		Runtime
	)

	local configuredSessions: SessionMap = options.sessions or options.lifecycleSessions or {}
	for name, resolver in pairs(configuredSessions) do
		runtime:session(name, resolver)
	end

	return runtime
end

function Runtime._assertOpen(self: Runtime)
	if self._destroyed then
		error("Runtime has been destroyed", 3)
	end
end

function Runtime.system(self: Runtime): unknown
	return self._system
end

function Runtime.diagnostics(self: Runtime): DiagnosticsSink
	return self._diagnostics
end

function Runtime._gate(self: Runtime): unknown
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

function Runtime._asyncPolicy(self: Runtime, actionName: string): unknown
	return ActionInvoker.asyncPolicy(self._system, actionName)
end

function Runtime.session(self: Runtime, name: string, resolverOrSession: unknown): Runtime
	self:_assertOpen()
	assertName("Runtime session name", name)
	if resolverOrSession == nil then
		error("Runtime session resolver must not be nil", 2)
	end

	self._sessions[name] = resolverOrSession
	return self
end

function Runtime.implement(
	self: Runtime,
	actionName: string,
	handler: ActionHandler,
	options: { overwrite: boolean? }?
): Runtime
	self:_assertOpen()
	assertName("Action name", actionName)
	if type(handler) ~= "function" then
		error("Runtime.implement expects an action handler function", 2)
	end
	local system = self._system :: any
	if not system:hasAction(actionName) then
		error("Cannot implement unknown action: " .. actionName, 2)
	end
	local handlers = self._handlers
	local overwrite = options ~= nil and options.overwrite == true
	if handlers[actionName] ~= nil and not overwrite then
		error("Runtime action already implemented: " .. actionName, 2)
	end

	handlers[actionName] = handler
	return self
end

function Runtime._normalizeRequest(self: Runtime, actionName: string, request: Request?): NormalizedRequest
	return RuntimeRequest.normalize(actionName, request, self._diagnostics)
end

function Runtime._failure(self: Runtime, name: string, message: string, request: NormalizedRequest): unknown
	local category = "runtime"
	if string.sub(name, 1, 9) == "Lifecycle" then
		category = "lifecycle"
	end

	return Result.failWithDiagnostic(request.diagnostics or self._diagnostics, {
		level = "error",
		category = category,
		system = systemName(self._system),
		name = name,
		message = message,
		context = {
			action = request.action,
			remote = request.remote,
			session = request.sessionName,
		},
	}, {
		context = request.context,
	})
end

function Runtime._resolveSession(self: Runtime, request: NormalizedRequest): (unknown?, boolean, unknown?)
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

	local resolveSession = resolver :: SessionResolver
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

function Runtime.invoke(self: Runtime, actionName: string, request: Request?): unknown
	self:_assertOpen()
	assertName("Action name", actionName)

	local handler = self._handlers[actionName]
	if handler == nil then
		error("Runtime action is not implemented: " .. actionName, 2)
	end
	local actionHandler = handler :: ActionHandler

	local runtimeRequest = self:_normalizeRequest(actionName, request)
	local session, ok, failure = self:_resolveSession(runtimeRequest)
	if not ok then
		return failure
	end

	local asyncPolicy = self:_asyncPolicy(actionName)
	local asyncGateResolver: (() -> unknown)? = nil
	if asyncPolicy ~= nil then
		asyncGateResolver = function(): unknown
			return self:_gate()
		end
	end

	return ActionInvoker.run({
		system = self._system,
		action = actionName,
		actor = runtimeRequest.actor,
		payload = runtimeRequest.payload,
		context = runtimeRequest.context,
		diagnostics = runtimeRequest.diagnostics,
		session = session,
		states = runtimeRequest.states,
		expectedRevision = runtimeRequest.expectedRevision,
		remote = runtimeRequest.remote,
		validated = false,
		handler = actionHandler,
		handlerRequest = runtimeRequest,
		asyncPolicy = asyncPolicy,
		asyncGateResolver = asyncGateResolver,
		pipeline = function(info: PipelineInfo, run: unknown): unknown
			return self:_runPipeline(info, run)
		end,
	})
end

function Runtime._pipelineClock(self: Runtime): () -> number
	local scheduler = self._scheduler
	if scheduler ~= nil and type(scheduler.clock) == "function" then
		return scheduler.clock :: () -> number
	end
	return function()
		if os and os.clock then
			return os.clock()
		end
		return 0
	end
end

function Runtime.onAction(self: Runtime, handlers: TapHandlers): () -> ()
	self:_assertOpen()
	if type(handlers) ~= "table" then
		error("Runtime.onAction expects a table of handlers", 2)
	end
	if handlers.started ~= nil and type(handlers.started) ~= "function" then
		error("Runtime.onAction started handler must be a function", 2)
	end
	if handlers.settled ~= nil and type(handlers.settled) ~= "function" then
		error("Runtime.onAction settled handler must be a function", 2)
	end
	if handlers.started == nil and handlers.settled == nil then
		error("Runtime.onAction expects a started or settled handler", 2)
	end

	local token = {}
	self._taps[token] = {
		started = handlers.started,
		settled = handlers.settled,
	}

	return function()
		self._taps[token] = nil
	end
end

function Runtime._emitTap(self: Runtime, phase: string, event: unknown)
	for token, tap in pairs(self._taps) do
		local listener = (tap :: any)[phase]
		if listener ~= nil then
			local ok, err = pcall(listener, event)
			if not ok then
				-- A tap is an observability hook; drop the one that errored, but
				-- record why so a crashing metrics/logging tap is not lost silently.
				self._taps[token] = nil
				Result.record(self._diagnostics, {
					level = "warn",
					category = "runtime",
					system = systemName(self._system),
					name = "RuntimeTapError",
					message = "tap listener for phase '"
						.. tostring(phase)
						.. "' errored and was removed: "
						.. tostring(err),
					context = {
						phase = phase,
					},
				})
			end
		end
	end
end

function Runtime.use(self: Runtime, middlewareFn: Middleware, options: UseOptions?): () -> ()
	self:_assertOpen()
	if type(middlewareFn) ~= "function" then
		error("Runtime.use expects a middleware function", 2)
	end

	local useOptions: UseOptions = options or {}
	local actions = nil
	if useOptions.actions ~= nil then
		if type(useOptions.actions) ~= "table" then
			error("Runtime.use actions filter must be a list of action names", 2)
		end
		actions = {}
		for _, actionName in ipairs(useOptions.actions) do
			if type(actionName) ~= "string" then
				error("Runtime.use actions filter must be a list of action names", 2)
			end
			actions[actionName] = true
		end
	end

	local entry = {
		fn = middlewareFn,
		actions = actions,
	}
	table.insert(self._middleware, entry)

	return function()
		for index, candidate in ipairs(self._middleware) do
			if candidate == entry then
				table.remove(self._middleware, index)
				break
			end
		end
	end
end

function Runtime._middlewareFailure(self: Runtime, info: PipelineInfo, name: string, message: string): unknown
	return Result.failWithDiagnostic(info.diagnostics or self._diagnostics, {
		level = "error",
		category = "runtime",
		system = systemName(self._system),
		name = name,
		message = message,
		context = {
			action = info.action,
			remote = info.remote,
		},
	})
end

function Runtime._runPipeline(self: Runtime, info: PipelineInfo, run: unknown): unknown
	return RuntimePipeline.run(self, info, run)
end

function Runtime.cancelActor(self: Runtime, actor: unknown, reason: unknown?): unknown
	if self._asyncGate == nil then
		return {
			cancelledRuns = 0,
			purgedWaiters = 0,
		}
	end

	local gate = self._asyncGate :: any
	return gate:cancelActor(actor, reason)
end

function Runtime.bindRemote(self: Runtime, remoteName: string, remoteObject: unknown, options: unknown?): unknown
	return RuntimeRemoteBinding.bind(self, remoteName, remoteObject, options)
end

function Runtime.bindRemotes(self: Runtime, remoteMap: unknown, options: unknown?): Runtime
	self:_assertOpen()
	if type(remoteMap) ~= "table" then
		error("Runtime.bindRemotes expects a map of remotes", 2)
	end

	for remoteName, remoteObject in pairs(remoteMap :: { [unknown]: unknown }) do
		if type(remoteName) == "string" then
			self:bindRemote(remoteName, remoteObject, options)
		end
	end
	return self
end

function Runtime.describe(self: Runtime): unknown
	local system = self._system :: any
	local describeFn = system.describe :: (any) -> unknown
	return {
		system = describeFn(system),
		implementedActions = sortedKeys(self._handlers),
		boundRemotes = sortedKeys(self._boundRemotes),
		sessions = sortedKeys(self._sessions),
		destroyed = self._destroyed,
	}
end

function Runtime.destroy(self: Runtime): Runtime
	if self._destroyed then
		return self
	end

	for _, connection in pairs(self._connections) do
		disconnect(connection)
	end

	if self._asyncGate ~= nil then
		local gate = self._asyncGate :: any
		gate:destroy()
		self._asyncGate = nil
	end

	self._connections = {}
	self._boundRemotes = {}
	self._destroyed = true
	return self
end

return Runtime
