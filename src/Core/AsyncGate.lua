--!strict

-- AsyncGate serializes (or rejects) overlapping in-flight calls that cross a
-- yield. Roblox server code is single-threaded, so concurrency only arises across
-- yields -- synchronous, non-yielding sequences are never racy. See
-- docs/ENGINEERING.md "Concurrency and Threading Model".

local AsyncGateExecution = require("./AsyncGateExecution")
local AsyncGateResults = require("./AsyncGateResults")
local Token = require("./AsyncToken")

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

local CONCURRENCY_MODES: { [string]: boolean } = {
	serialize = true,
	reject = true,
	allow = true,
}

local function failure(name: string, reason: string, options: any): any
	return AsyncGateResults.failure(name, reason, options)
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

	table.insert(lock.queue, {
		thread = coroutine.running(),
		actor = options.actor,
	})
	local signal, signalReason = coroutine.yield()

	if signal == "cancelled" then
		local subject = tostring(options.action or options.remote or "action")
		return failure(
			"ActionCancelled",
			subject .. " cancelled while queued (" .. tostring(signalReason) .. ")",
			options
		)
	end
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

	local nextEntry = table.remove(lock.queue, 1)
	if nextEntry == nil then
		self._locks[key] = nil
		return
	end

	local spawnFn = self._scheduler.spawn :: (any) -> any
	spawnFn(nextEntry.thread)
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

	if type(runOptions.onStarted) == "function" then
		pcall(runOptions.onStarted)
	end

	local released = false
	local function releaseLock()
		if released then
			return
		end
		released = true
		self:_release(key, concurrency)
	end

	local result, releaseDeferred = AsyncGateExecution.execute(self, runOptions, fn, releaseLock)
	if not releaseDeferred then
		releaseLock()
	end
	return result
end

function AsyncGate.activeCount(self: any): number
	local count = 0
	for _ in pairs(self._tokens) do
		count += 1
	end
	return count
end

function AsyncGate.cancelActor(self: any, actor: any, reason: any?): any
	local summary = {
		cancelledRuns = 0,
		purgedWaiters = 0,
	}
	if self._destroyed or actor == nil then
		return summary
	end

	local cancelReason = reason or "cancelled"

	-- Purge queued waiters before settling in-flight runs: settling first would
	-- release the lock and start the same actor's next queued run. Purge EVERY
	-- lock before resuming any waiter: a resumed continuation can release
	-- another lock (handing it to a waiter that should have been purged) or
	-- re-enter the gate and grow _locks mid-traversal.
	local purged: { any } = {}
	for _, lock in pairs(self._locks) do
		local kept: { any } = {}
		for _, entry in ipairs(lock.queue) do
			if entry.actor == actor then
				table.insert(purged, entry)
			else
				table.insert(kept, entry)
			end
		end
		lock.queue = kept
	end

	for _, entry in ipairs(purged) do
		summary.purgedWaiters += 1
		local spawnFn = self._scheduler.spawn :: (any, any, any) -> any
		spawnFn(entry.thread, "cancelled", cancelReason)
	end

	-- Snapshot before settling: resumed callers re-enter gate code synchronously
	-- and mutate _tokens mid-iteration.
	local inFlight: { any } = {}
	for token, entry in pairs(self._tokens) do
		if entry.actor == actor then
			table.insert(inFlight, {
				token = token,
				entry = entry,
			})
		end
	end

	for _, item in ipairs(inFlight) do
		item.token:cancel(cancelReason)
		-- No diagnostic here: the commit-boundary check in System.runAction
		-- records ActionCancelled for in-flight runs. An earlier settle's
		-- continuation may have settled this run naturally; settle reports
		-- whether this call actually cancelled it.
		local settled = item.entry.settle(
			AsyncGateResults.failureResult("ActionCancelled", "action cancelled (" .. tostring(cancelReason) .. ")")
		)
		if settled then
			summary.cancelledRuns += 1
		end
	end

	return summary
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
		for _, entry in ipairs(lock.queue) do
			local spawnFn = self._scheduler.spawn :: (any) -> any
			spawnFn(entry.thread)
		end
	end
	self._locks = {}
end

return AsyncGate
