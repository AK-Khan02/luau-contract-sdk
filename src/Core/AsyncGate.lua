--!strict

export type Scheduler = {
	spawn: (any, ...any) -> any,
	delay: (number, () -> ()) -> any,
	clock: (() -> number)?,
}

export type AsyncPolicy = {
	timeoutSeconds: any?,
	concurrency: string?,
}

local AsyncGate: any = {}
AsyncGate.__index = AsyncGate

local DEFAULT_TIMEOUT_SECONDS = 10

local CONCURRENCY_MODES: {[string]: boolean} = {
	serialize = true,
	reject = true,
	allow = true,
}

local Token: any = {}
Token.__index = Token

function Token.new(): any
	return setmetatable({
		_cancelled = false,
		_reason = nil,
		_callbacks = {},
	}, Token)
end

function Token.isCancelled(self: any): boolean
	return self._cancelled
end

function Token.reason(self: any): any
	return self._reason
end

function Token.cancel(self: any, reason: any?)
	if self._cancelled then
		return
	end
	self._cancelled = true
	self._reason = reason or "cancelled"

	local callbacks = self._callbacks
	self._callbacks = {}
	for _, callback in ipairs(callbacks) do
		pcall(callback, self._reason)
	end
end

function Token.onCancel(self: any, callback: (any) -> ())
	if type(callback) ~= "function" then
		error("Token.onCancel expects a callback function", 2)
	end
	if self._cancelled then
		pcall(callback, self._reason)
		return
	end
	table.insert(self._callbacks, callback)
end

local function record(diagnostics: any, fields: any)
	if diagnostics and diagnostics.record then
		local target: any = diagnostics
		target:record(fields)
	end
end

local function failure(name: string, reason: string, options: any): any
	record(options.diagnostics, {
		level = "error",
		category = "action",
		system = options.system,
		name = name,
		message = reason,
		context = {
			action = options.action,
			remote = options.remote,
		},
	})

	return {
		ok = false,
		name = name,
		reason = reason,
	}
end

function AsyncGate.token(): any
	return Token.new()
end

function AsyncGate.normalizeTimeout(timeoutSeconds: any): any
	if timeoutSeconds == false then
		return nil
	end
	if timeoutSeconds == nil then
		return DEFAULT_TIMEOUT_SECONDS
	end
	if type(timeoutSeconds) ~= "number" or timeoutSeconds <= 0 then
		error("Async timeoutSeconds must be a positive number or false", 3)
	end
	return timeoutSeconds
end

function AsyncGate.normalizeConcurrency(concurrency: any, hasSession: boolean): string
	if concurrency == nil then
		return hasSession and "serialize" or "reject"
	end
	if CONCURRENCY_MODES[concurrency] ~= true then
		error("Async concurrency must be serialize, reject, or allow", 3)
	end
	return concurrency
end

function AsyncGate.new(config: any): any
	local gateConfig: any = config or {}
	local scheduler = gateConfig.scheduler
	if scheduler == nil or type(scheduler.spawn) ~= "function" or type(scheduler.delay) ~= "function" then
		error("AsyncGate.new expects a scheduler with spawn and delay", 2)
	end

	return setmetatable({
		_scheduler = scheduler,
		_locks = {},
		_tokens = {},
		_destroyed = false,
	}, AsyncGate)
end

function AsyncGate._acquire(self: any, key: any, concurrency: string, options: any): any
	if concurrency == "allow" then
		return {
			ok = true,
		}
	end

	local lock = self._locks[key]
	if lock == nil then
		self._locks[key] = {
			queue = {},
		}
		return {
			ok = true,
		}
	end

	if concurrency == "reject" then
		local subject = tostring(options.action or options.remote or "action")
		return failure("ActionBusy", subject .. " is already running for this session", options)
	end

	table.insert(lock.queue, coroutine.running())
	coroutine.yield()

	if self._destroyed then
		return failure("ActionCancelled", "async gate destroyed while queued", options)
	end
	return {
		ok = true,
	}
end

function AsyncGate._release(self: any, key: any, concurrency: string)
	if concurrency == "allow" then
		return
	end

	local lock = self._locks[key]
	if lock == nil then
		return
	end

	local nextThread = table.remove(lock.queue, 1)
	if nextThread == nil then
		self._locks[key] = nil
		return
	end

	local spawnFn = self._scheduler.spawn :: (any) -> any
	spawnFn(nextThread)
end

function AsyncGate._execute(self: any, options: any, fn: (any) -> any): any
	local token = Token.new()
	self._tokens[token] = true

	local callerThread = coroutine.running()
	local settled = false
	local waiting = false
	local syncResult = nil

	local function settle(result: any): boolean
		if settled then
			return false
		end
		settled = true
		self._tokens[token] = nil
		if waiting then
			local spawnFn = self._scheduler.spawn :: (any, any) -> any
			spawnFn(callerThread, result)
		else
			syncResult = result
		end
		return true
	end

	local spawnFn = self._scheduler.spawn :: (any) -> any
	spawnFn(function()
		local ok, value = pcall(fn, token)
		if not ok then
			settle(failure("ActionHandlerError", tostring(value), options))
			return
		end
		settle(value)
	end)

	if settled then
		return syncResult
	end

	waiting = true
	local timeoutSeconds = options.timeoutSeconds
	if timeoutSeconds ~= nil then
		local delayFn = self._scheduler.delay :: (number, () -> ()) -> any
		delayFn(timeoutSeconds, function()
			if settled then
				return
			end
			token:cancel("timeout")
			local subject = tostring(options.action or options.remote or "action")
			settle(failure(
				"ActionTimeout",
				subject .. " timed out after " .. tostring(timeoutSeconds) .. " seconds",
				options
			))
		end)
	end

	return coroutine.yield()
end

function AsyncGate.run(self: any, key: any, options: any, fn: (any) -> any): any
	if self._destroyed then
		error("AsyncGate has been destroyed", 2)
	end
	if type(fn) ~= "function" then
		error("AsyncGate.run expects a function", 2)
	end

	local runOptions: any = options or {}
	local concurrency = runOptions.concurrency or "reject"
	if CONCURRENCY_MODES[concurrency] ~= true then
		error("AsyncGate.run concurrency must be serialize, reject, or allow", 2)
	end
	if key == nil then
		key = "__global"
	end

	local acquired = self:_acquire(key, concurrency, runOptions)
	if not acquired.ok then
		return acquired
	end

	local result = self:_execute(runOptions, fn)
	self:_release(key, concurrency)
	return result
end

function AsyncGate.activeCount(self: any): number
	local count = 0
	for _ in pairs(self._tokens) do
		count += 1
	end
	return count
end

function AsyncGate.destroy(self: any)
	if self._destroyed then
		return
	end
	self._destroyed = true

	for token in pairs(self._tokens) do
		token:cancel("destroyed")
	end
	self._tokens = {}

	for _, lock in pairs(self._locks) do
		for _, thread in ipairs(lock.queue) do
			local spawnFn = self._scheduler.spawn :: (any) -> any
			spawnFn(thread)
		end
	end
	self._locks = {}
end

return AsyncGate
