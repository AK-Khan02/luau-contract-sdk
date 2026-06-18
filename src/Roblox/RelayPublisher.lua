--!strict

local DiagnosticsBridge = require("../Studio/DiagnosticsBridge")
local JsonEncode = require("../Host/JsonEncode")
local PlayersService = require("./PlayersService")
local TaskScheduler = require("./TaskScheduler")

local RelayPublisher = {}

type Scheduler = TaskScheduler.Scheduler

type Stats = {
	sent: number,
	retried: number,
	droppedRetry: number,
	droppedOutbox: number,
	disabled: boolean,
}

local ENVELOPE_VERSION = 1
local DEFAULT_LEVEL = "error"
local DEFAULT_MAX_OUTBOX = 50
local DEFAULT_MAX_REQUESTS_PER_MINUTE = 30
local DEFAULT_MAX_ATTEMPTS = 5
local MAX_BACKOFF_SECONDS = 30
local AUTH_FAILURE_LATCH = 3

local function isStudio(runService: any): boolean
	if runService == nil or type(runService.IsStudio) ~= "function" then
		return false
	end
	local isStudioFn = runService.IsStudio :: (any) -> any
	local ok, value = pcall(isStudioFn, runService)
	return ok and value == true
end

local function connectHeartbeat(runService: any, callback: () -> ()): any
	if runService == nil then
		return nil
	end
	local heartbeat = runService.Heartbeat
	if heartbeat == nil or type(heartbeat.Connect) ~= "function" then
		return nil
	end
	local connect = heartbeat.Connect :: (any, () -> ()) -> any
	return connect(heartbeat, callback) -- contracts-scan: ignore raw-remote-handler
end

local function disconnect(connection: any)
	if connection and type(connection.Disconnect) == "function" then
		local disconnectFn = connection.Disconnect :: (any) -> ()
		disconnectFn(connection)
	end
end

local function defaultServerId(): string
	local jobId = PlayersService.jobId()
	if type(jobId) == "string" and jobId ~= "" then
		return jobId
	end
	return "studio"
end

local function defaultPlaceVersion(): number?
	local placeVersion = PlayersService.placeVersion()
	if type(placeVersion) == "number" then
		return placeVersion
	end
	return nil
end

local function defaultWait(): ((number) -> ())?
	local taskLib = PlayersService.resolveTaskLibrary()
	if type(taskLib) == "table" and type(taskLib.wait) == "function" then
		local waitFn = taskLib.wait :: (number) -> ()
		return function(seconds: number)
			waitFn(seconds)
		end
	end
	return nil
end

local function backoffSeconds(attempts: number): number
	local backoff = 2 ^ (attempts - 1)
	if backoff > MAX_BACKOFF_SECONDS then
		return MAX_BACKOFF_SECONDS
	end
	return backoff
end

local function noopHandle(): any
	return {
		enabled = false,
		flush = function()
			return nil
		end,
		step = function() end,
		drain = function()
			return 0
		end,
		stats = function()
			return {
				sent = 0,
				retried = 0,
				droppedRetry = 0,
				droppedOutbox = 0,
				disabled = false,
				pending = 0,
			}
		end,
		destroy = function() end,
	}
end

function RelayPublisher.publish(diagnostics: any, options: any): any
	options = options or {}

	if type(options.endpoint) ~= "string" or options.endpoint == "" then
		error("RelayPublisher.publish requires options.endpoint", 2)
	end

	local runService = options.runService or PlayersService.resolveService("RunService")
	if isStudio(runService) and options.studio ~= true then
		return noopHandle()
	end

	local httpService = options.httpService or PlayersService.resolveService("HttpService")
	if httpService == nil or type(httpService.RequestAsync) ~= "function" then
		error("RelayPublisher.publish needs an HttpService with RequestAsync; pass options.httpService", 2)
	end

	local scheduler: Scheduler? = options.scheduler :: Scheduler?
	if scheduler == nil then
		scheduler = TaskScheduler.default()
	end
	if scheduler == nil then
		error("RelayPublisher.publish needs a scheduler; pass options.scheduler", 2)
	end
	local activeScheduler = scheduler :: Scheduler

	local clock: () -> number = os.clock
	if type(activeScheduler.clock) == "function" then
		clock = activeScheduler.clock :: () -> number
	end
	if type(options.clock) == "function" then
		clock = options.clock :: () -> number
	end
	local endpoint: string = options.endpoint
	local apiKey = options.apiKey
	local serverId: string = if type(options.serverId) == "string" then options.serverId else defaultServerId()
	local placeVersion: number? = if type(options.placeVersion) == "number"
		then options.placeVersion
		else defaultPlaceVersion()
	local maxOutbox: number = if type(options.maxOutbox) == "number" then options.maxOutbox else DEFAULT_MAX_OUTBOX
	local maxRequestsPerMinute: number = if type(options.maxRequestsPerMinute) == "number"
		then options.maxRequestsPerMinute
		else DEFAULT_MAX_REQUESTS_PER_MINUTE
	local maxAttempts: number = if type(options.maxAttempts) == "number"
		then options.maxAttempts
		else DEFAULT_MAX_ATTEMPTS
	local wait: ((number) -> ())? = if type(options.wait) == "function" then options.wait else defaultWait()

	local outbox: { any } = {}
	local stats: Stats = {
		sent = 0,
		retried = 0,
		droppedRetry = 0,
		droppedOutbox = 0,
		disabled = false,
	}
	local relayDropped = 0
	local authFailures = 0
	local sending = false
	local retryAt = 0
	local attempts = 0
	local windowStart = clock()
	local requestsInWindow = 0
	local destroyed = false

	-- onBatch runs synchronously inside Diagnostics:record, which runs inside
	-- the action pipeline: it must only enqueue, never perform HTTP.
	local function enqueue(batch: any)
		table.insert(outbox, batch)
		while #outbox > maxOutbox do
			table.remove(outbox, 1)
			stats.droppedOutbox += 1
			relayDropped += 1
		end
	end

	local bridge = DiagnosticsBridge.new(diagnostics, {
		level = options.level or DEFAULT_LEVEL,
		replay = options.replay,
		maxBatchEntries = options.maxBatchEntries,
		flushIntervalSeconds = options.flushIntervalSeconds,
		maxContextDepth = options.maxContextDepth,
		clock = clock,
		onBatch = enqueue,
	})

	local function budgetAvailable(): boolean
		local now = clock()
		if now - windowStart >= 60 then
			windowStart = now
			requestsInWindow = 0
		end
		return requestsInWindow < maxRequestsPerMinute
	end

	-- The outbox can shift while a send is in flight (enqueue evicts from the
	-- front on overflow), so completion paths must remove the attempted batches
	-- by identity, never by position.
	local function removeBatches(batches: { any }): number
		local removing: { [any]: boolean } = {}
		for _, batch in ipairs(batches) do
			removing[batch] = true
		end

		local kept: { any } = {}
		local removed = 0
		for _, batch in ipairs(outbox) do
			if removing[batch] then
				removed += 1
			else
				table.insert(kept, batch)
			end
		end
		outbox = kept
		return removed
	end

	local function dropBatches(batches: { any })
		local removed = removeBatches(batches)
		stats.droppedRetry += removed
		relayDropped += removed
		attempts = 0
	end

	-- Surface the latch loudly: once the relay disables itself the game would
	-- otherwise stop relaying with no signal beyond stats.disabled. Record a
	-- diagnostic (best effort) and fire an optional onDisabled hook. Runs from
	-- send(), i.e. inside a spawned task rather than synchronously under
	-- Diagnostics:record, so recording here cannot re-enter the pipeline.
	local function recordDisabled()
		if diagnostics ~= nil and type(diagnostics.record) == "function" then
			local recordFn = diagnostics.record :: (any, any) -> any
			pcall(recordFn, diagnostics, {
				level = "error",
				category = "relay",
				name = "RelayPublisherDisabled",
				message = "relay publisher disabled after "
					.. tostring(authFailures)
					.. " consecutive auth failures (401); diagnostics will no longer be relayed",
				context = {
					endpoint = endpoint,
					authFailures = authFailures,
				},
			})
		end
		if type(options.onDisabled) == "function" then
			local onDisabled = options.onDisabled :: (any) -> ()
			pcall(onDisabled, {
				reason = "authFailures",
				authFailures = authFailures,
				endpoint = endpoint,
			})
		end
	end

	local function send()
		local batchCount = #outbox
		local batches: { any } = {}
		for index = 1, batchCount do
			batches[index] = outbox[index]
		end

		local envelope = {
			v = ENVELOPE_VERSION,
			serverId = serverId,
			placeVersion = placeVersion,
			relayDropped = relayDropped,
			batches = batches,
		}

		requestsInWindow += 1
		local requestAsync = httpService.RequestAsync :: (any, any) -> any
		local ok, response = pcall(function()
			return requestAsync(httpService, {
				Url = endpoint,
				Method = "POST",
				Headers = {
					["Content-Type"] = "application/json",
					["x-api-key"] = apiKey,
				},
				Body = JsonEncode.encode(envelope),
			})
		end)

		local status = ok and type(response) == "table" and response.StatusCode or nil
		if ok and status ~= nil and status >= 200 and status < 300 then
			removeBatches(batches)
			stats.sent += 1
			attempts = 0
			authFailures = 0
			relayDropped = 0
			return
		end

		if status == 401 then
			authFailures += 1
			dropBatches(batches)
			if authFailures >= AUTH_FAILURE_LATCH and not stats.disabled then
				stats.disabled = true
				recordDisabled()
			end
			return
		end

		if status == 400 or status == 403 then
			dropBatches(batches)
			return
		end

		-- pcall failure, 5xx, 429, or malformed response: retry with backoff.
		attempts += 1
		stats.retried += 1
		if attempts >= maxAttempts then
			dropBatches(batches)
			return
		end
		retryAt = clock() + backoffSeconds(attempts)
	end

	local function pump()
		if destroyed or stats.disabled or sending or #outbox == 0 then
			return
		end
		if clock() < retryAt then
			return
		end
		if not budgetAvailable() then
			return
		end

		sending = true
		activeScheduler.spawn(function()
			send()
			sending = false
		end)
	end

	local function step()
		bridge:step()
		pump()
	end

	local connection = connectHeartbeat(runService, step)

	local handle = {
		enabled = true,
		bridge = bridge,
	}

	function handle.flush(): any
		local batch = bridge:flush()
		pump()
		return batch
	end

	function handle.step()
		step()
	end

	function handle.stats()
		return {
			sent = stats.sent,
			retried = stats.retried,
			droppedRetry = stats.droppedRetry,
			droppedOutbox = stats.droppedOutbox,
			disabled = stats.disabled,
			pending = #outbox,
		}
	end

	function handle.drain(timeoutSeconds: number?): number
		bridge:flush()
		local deadline = clock() + (timeoutSeconds or 5)
		while #outbox > 0 and clock() < deadline and not stats.disabled do
			pump()
			if wait == nil then
				break
			end
			local waitFn = wait :: (number) -> ()
			waitFn(0.05)
		end
		return #outbox
	end

	function handle.destroy()
		if destroyed then
			return
		end
		bridge:flush()
		bridge:destroy()
		disconnect(connection)
		destroyed = true
	end

	return handle
end

return RelayPublisher
