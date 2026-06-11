--!nocheck

local Contracts = require("../../src/Contracts")
local RelayPublisher = require("../../src/Roblox/RelayPublisher")
local ManualScheduler = require("../../src/Test/ManualScheduler")

local function fakeHttp(plan)
	local service = {
		requests = {},
	}
	function service:RequestAsync(request)
		table.insert(self.requests, request)
		local step = table.remove(plan, 1) or { status = 200 }
		if step.fail then
			error("connection refused")
		end
		return {
			Success = step.status >= 200 and step.status < 300,
			StatusCode = step.status,
		}
	end
	return service
end

local function fakeRunService(studio)
	return {
		IsStudio = function()
			return studio
		end,
	}
end

local function newPublisher(plan, overrides)
	local sched = ManualScheduler.new(0)
	local diagnostics = Contracts.diagnostics({
		clock = sched.clock,
	})
	local http = fakeHttp(plan or {})
	local options = {
		endpoint = "https://relay.example/ingest",
		apiKey = "secret",
		httpService = http,
		runService = fakeRunService(false),
		scheduler = sched,
		serverId = "test-server",
		placeVersion = 42,
		flushIntervalSeconds = 0.25,
	}
	for key, value in pairs(overrides or {}) do
		options[key] = value
	end
	local handle = RelayPublisher.publish(diagnostics, options)
	return handle, diagnostics, http, sched
end

return function(test)
	local function check(name, condition)
		test:check(name, condition)
	end

	test:section("RelayPublisher")

	check("publish requires an endpoint", pcall(function()
		RelayPublisher.publish(Contracts.diagnostics(), {
			httpService = fakeHttp({}),
			scheduler = ManualScheduler.new(),
		})
	end) == false)

	local studioHandle = RelayPublisher.publish(Contracts.diagnostics(), {
		endpoint = "https://relay.example/ingest",
		httpService = fakeHttp({}),
		runService = fakeRunService(true),
		scheduler = ManualScheduler.new(),
	})
	check("publish is a no-op in Studio by default", studioHandle.enabled == false)
	check("noop handle reports the same stats shape as a live handle", (function()
		local stats = studioHandle.stats()
		return stats.sent == 0 and stats.retried == 0 and stats.droppedRetry == 0
			and stats.droppedOutbox == 0 and stats.disabled == false and stats.pending == 0
	end)())

	local studioForced = RelayPublisher.publish(Contracts.diagnostics(), {
		endpoint = "https://relay.example/ingest",
		httpService = fakeHttp({}),
		runService = fakeRunService(true),
		scheduler = ManualScheduler.new(),
		studio = true,
	})
	check("studio = true overrides the gate", studioForced.enabled == true)
	studioForced.destroy()

	local handle, diagnostics, http = newPublisher()
	diagnostics:record({ level = "error", system = "InventoryService", name = "RemoteRateLimited", message = "too fast" })
	check("recording does not send synchronously", #http.requests == 0)
	check("relay defaults filter below error", (function()
		diagnostics:record({ level = "warn", name = "Ignored" })
		return handle.bridge:pendingCount() == 1
	end)())

	handle.step()
	check("step flushes and sends one request", #http.requests == 1)
	check("request targets the endpoint with the api key", http.requests[1].Url == "https://relay.example/ingest"
		and http.requests[1].Headers["x-api-key"] == "secret"
		and http.requests[1].Method == "POST")
	test:expectMatch("envelope carries server identity", http.requests[1].Body, "\"serverId\":\"test-server\"")
	test:expectMatch("envelope carries the wire version", http.requests[1].Body, "\"v\":1")
	test:expectMatch("envelope carries entries", http.requests[1].Body, "RemoteRateLimited")
	check("send updates stats", handle.stats().sent == 1 and handle.stats().pending == 0)
	handle.destroy()

	test:section("RelayPublisher retry and backoff")

	local retryHandle, retryDiag, retryHttp, retrySched = newPublisher({
		{ status = 500 },
		{ status = 200 },
	})
	retryDiag:record({ level = "error", name = "First" })
	retryHandle.step()
	check("failed send marks a retry", #retryHttp.requests == 1 and retryHandle.stats().retried == 1)
	retryHandle.step()
	check("retry waits for backoff", #retryHttp.requests == 1)
	retrySched.advance(1)
	retryDiag:record({ level = "error", name = "Second" })
	retrySched.advance(0.3)
	retryHandle.step()
	check("retry resends after backoff", #retryHttp.requests == 2)
	test:expectMatch("retried envelope coalesces queued batches", retryHttp.requests[2].Body, "First")
	test:expectMatch("retried envelope includes newer batches", retryHttp.requests[2].Body, "Second")
	check("success clears pending and counts sent", retryHandle.stats().sent == 1 and retryHandle.stats().pending == 0)
	retryHandle.destroy()

	local exhaustHandle, exhaustDiag, exhaustHttp, exhaustSched = newPublisher({
		{ fail = true },
		{ fail = true },
	}, {
		maxAttempts = 2,
	})
	exhaustDiag:record({ level = "error", name = "Doomed" })
	exhaustHandle.step()
	exhaustSched.advance(2)
	exhaustHandle.step()
	check("retry exhaustion drops the batch", #exhaustHttp.requests == 2
		and exhaustHandle.stats().droppedRetry == 1 and exhaustHandle.stats().pending == 0)
	exhaustHandle.destroy()

	test:section("RelayPublisher budget and caps")

	local budgetHandle, budgetDiag, budgetHttp, budgetSched = newPublisher({}, {
		maxRequestsPerMinute = 2,
	})
	for index = 1, 3 do
		budgetDiag:record({ level = "error", name = "Entry" .. index })
		budgetSched.advance(0.3)
		budgetHandle.step()
	end
	check("budget caps requests per minute", #budgetHttp.requests == 2 and budgetHandle.stats().pending == 1)
	budgetSched.advance(60)
	budgetHandle.step()
	check("budget window rolls and resumes sending", #budgetHttp.requests == 3 and budgetHandle.stats().pending == 0)
	budgetHandle.destroy()

	local capHandle, capDiag = newPublisher({}, {
		maxOutbox = 2,
		maxRequestsPerMinute = 0,
	})
	for index = 1, 3 do
		capDiag:record({ level = "error", name = "Backlog" .. index })
		capHandle.flush()
	end
	check("outbox cap evicts oldest batches", capHandle.stats().droppedOutbox == 1 and capHandle.stats().pending == 2)
	capHandle.destroy()

	test:section("RelayPublisher in-flight eviction")

	-- RequestAsync yields in Roblox, so Heartbeat keeps enqueueing while a send
	-- is in flight. Outbox-cap eviction during the request must not cause the
	-- completion path to discard batches that were never part of the send.
	local racingPlan = { { status = 200 }, { status = 200 } }
	local midRequest = nil
	local racingHttp = {
		requests = {},
	}
	function racingHttp:RequestAsync(request)
		table.insert(self.requests, request)
		if midRequest ~= nil then
			local hook = midRequest
			midRequest = nil
			hook()
		end
		local step = table.remove(racingPlan, 1) or { status = 200 }
		return {
			Success = step.status >= 200 and step.status < 300,
			StatusCode = step.status,
		}
	end

	local raceHandle, raceDiag = newPublisher(nil, {
		httpService = racingHttp,
		maxOutbox = 2,
	})
	midRequest = function()
		raceDiag:record({ level = "error", name = "EntryB" })
		raceHandle.flush()
		raceDiag:record({ level = "error", name = "EntryC" })
		raceHandle.flush()
	end
	raceDiag:record({ level = "error", name = "EntryA" })
	raceHandle.flush()
	check("in-flight eviction keeps unsent batches pending", raceHandle.stats().pending == 2)
	check("eviction during the send is still counted", raceHandle.stats().droppedOutbox == 1)
	raceHandle.flush()
	check("unsent batches go out on the next send", #racingHttp.requests == 2)
	test:expectMatch("second envelope carries the first surviving batch", racingHttp.requests[2].Body, "EntryB")
	test:expectMatch("second envelope carries the second surviving batch", racingHttp.requests[2].Body, "EntryC")
	raceHandle.destroy()

	test:section("RelayPublisher auth latch")

	local authHandle, authDiag, authHttp, authSched = newPublisher({
		{ status = 401 },
		{ status = 401 },
		{ status = 401 },
	})
	for index = 1, 3 do
		authDiag:record({ level = "error", name = "Auth" .. index })
		authSched.advance(0.3)
		authHandle.step()
	end
	check("repeated 401s latch the publisher off", authHandle.stats().disabled == true
		and #authHttp.requests == 3 and authHandle.stats().droppedRetry == 3)
	authDiag:record({ level = "error", name = "AfterLatch" })
	authSched.advance(0.3)
	authHandle.step()
	check("latched publisher stops sending", #authHttp.requests == 3)
	authHandle.destroy()

	test:section("RelayPublisher secrets and drain")

	local secretKey = setmetatable({}, {
		__tostring = function()
			error("secrets must not be stringified")
		end,
	})
	local secretHandle, secretDiag, secretHttp = newPublisher({}, {
		apiKey = secretKey,
	})
	secretDiag:record({ level = "error", name = "WithSecret" })
	secretHandle.step()
	check("api keys pass through untouched", secretHttp.requests[1].Headers["x-api-key"] == secretKey)
	secretHandle.destroy()

	local drainHandle, drainDiag = newPublisher({}, {
		wait = function() end,
	})
	drainDiag:record({ level = "error", name = "DrainMe" })
	local remaining = drainHandle.drain(1)
	check("drain flushes and empties the outbox", remaining == 0 and drainHandle.stats().sent == 1)
	drainHandle.destroy()
end
