--!nocheck

local Contracts = require("../../src/Contracts")
local AsyncGate = require("../../src/Core/AsyncGate")
local ManualScheduler = require("../../src/Test/ManualScheduler")

local function buildInventory()
	return Contracts.system("InventoryService")
		:action("GrantItem", {
			input = Contracts.object({
				id = Contracts.stringId(),
			}, {
				allowExtra = false,
			}),
			output = Contracts.object({
				granted = Contracts.boolean(),
			}, {
				allowExtra = false,
			}),
			writes = { "PlayerData/Inventory" },
			async = {
				timeoutSeconds = 5,
			},
		})
end

return function(test)
	local function check(name, condition)
		test:check(name, condition)
	end

	test:section("ManualScheduler")

	local sched = ManualScheduler.new(100)
	check("manual scheduler tracks time", sched.clock() == 100)

	local fired = {}
	local cancelTimer = sched.delay(5, function()
		table.insert(fired, "late")
	end)
	sched.delay(1, function()
		table.insert(fired, "early")
	end)
	sched.advance(2)
	check("advance fires due timers in order", #fired == 1 and fired[1] == "early")
	cancelTimer()
	sched.advance(10)
	check("cancelled timers never fire", #fired == 1 and sched.pendingTimerCount() == 0)

	local spawnOrder = {}
	sched.spawn(function()
		table.insert(spawnOrder, "ran")
	end)
	check("spawn runs immediately", spawnOrder[1] == "ran")

	test:section("AsyncGate")

	local gateSched = ManualScheduler.new()
	local gate = AsyncGate.new({
		scheduler = gateSched,
	})

	local syncResult = nil
	gateSched.spawn(function()
		syncResult = gate:run("key", { concurrency = "reject" }, function()
			return { ok = true, value = 42 }
		end)
	end)
	check("gate passes through synchronous completions", syncResult ~= nil and syncResult.value == 42)

	local threads = {}
	local results = {}
	local function yieldingRun(label, concurrency)
		gateSched.spawn(function()
			results[label] = gate:run("key", {
				concurrency = concurrency,
				action = "GrantItem",
			}, function()
				threads[label] = coroutine.running()
				coroutine.yield()
				return { ok = true, label = label }
			end)
		end)
	end

	yieldingRun("first", "reject")
	check("in-flight handler holds the lock", threads.first ~= nil and results.first == nil)

	local rejected = nil
	gateSched.spawn(function()
		rejected = gate:run("key", {
			concurrency = "reject",
			action = "GrantItem",
		}, function()
			return { ok = true }
		end)
	end)
	check("reject concurrency fails fast with ActionBusy", rejected ~= nil and rejected.ok == false and rejected.name == "ActionBusy")

	yieldingRun("second", "serialize")
	check("serialize concurrency queues behind in-flight call", threads.second == nil and results.second == nil)

	gateSched.spawn(threads.first)
	check("first call completes after resume", results.first ~= nil and results.first.label == "first")
	check("queued call starts when lock releases", threads.second ~= nil and results.second == nil)
	gateSched.spawn(threads.second)
	check("queued call completes in order", results.second ~= nil and results.second.label == "second")

	local timeoutDiag = Contracts.diagnostics()
	local timeoutResult = nil
	local timeoutToken = nil
	gateSched.spawn(function()
		timeoutResult = gate:run("slow", {
			concurrency = "reject",
			timeoutSeconds = 3,
			system = "InventoryService",
			action = "GrantItem",
			diagnostics = timeoutDiag,
		}, function(token)
			timeoutToken = token
			threads.slow = coroutine.running()
			coroutine.yield()
			return { ok = true, label = "slow" }
		end)
	end)
	check("timed call waits before deadline", timeoutResult == nil)
	gateSched.advance(3)
	check("gate times out stuck calls", timeoutResult ~= nil and timeoutResult.name == "ActionTimeout")
	check("timeout cancels the token", timeoutToken ~= nil and timeoutToken:isCancelled() and timeoutToken:reason() == "timeout")
	check("timeout records a diagnostic", #timeoutDiag:findByName("ActionTimeout") == 1)

	gateSched.spawn(threads.slow)
	check("late completion after timeout is discarded", timeoutResult.name == "ActionTimeout")

	local lockedAgain = nil
	gateSched.spawn(function()
		lockedAgain = gate:run("slow", { concurrency = "reject" }, function()
			return { ok = true, label = "fresh" }
		end)
	end)
	check("timeout releases the lock", lockedAgain ~= nil and lockedAgain.label == "fresh")

	test:section("Async actions end to end")

	local Inventory = buildInventory()
	local runtimeSched = ManualScheduler.new()
	local diagnostics = Contracts.diagnostics()
	local runtime = Contracts.runtime(Inventory, {
		diagnostics = diagnostics,
		scheduler = runtimeSched,
	})

	local commits = {}
	local rollbacks = {}
	local handlerThreads = {}
	local order = {}

	runtime:implement("GrantItem", function(scope)
		local id = scope:payload().id
		table.insert(order, "start:" .. id)
		scope:stageWrite("PlayerData/Inventory", {
			commit = function()
				table.insert(commits, id)
			end,
			rollback = function()
				table.insert(rollbacks, id)
			end,
		})

		handlerThreads[id] = coroutine.running()
		coroutine.yield()

		table.insert(order, "finish:" .. id)
		return {
			granted = true,
		}
	end)

	local session = Inventory:lifecycleSession({})
	local invokeResults = {}
	local function invokeAsync(slot, id)
		runtimeSched.spawn(function()
			invokeResults[slot] = runtime:invoke("GrantItem", {
				payload = {
					id = id,
				},
				session = session,
			})
		end)
	end

	invokeAsync(1, "sword")
	invokeAsync(2, "shield")
	check("serialize is the default with a session", #order == 1 and order[1] == "start:sword")

	runtimeSched.spawn(handlerThreads.sword)
	check("first async action commits", invokeResults[1] ~= nil and invokeResults[1].ok == true and commits[1] == "sword")
	check("queued duplicate starts only after first settles", order[3] == "start:shield")

	runtimeSched.spawn(handlerThreads.shield)
	check("queued duplicate commits second", invokeResults[2] ~= nil and invokeResults[2].ok == true and commits[2] == "shield")
	check("exactly one commit per call", #commits == 2 and #rollbacks == 0)

	invokeAsync(3, "bow")
	session:restore({
		revision = session:revision() + 1,
		states = session:states(),
	})
	runtimeSched.spawn(handlerThreads.bow)
	check("stale revision after yield refuses to apply", invokeResults[3] ~= nil and invokeResults[3].ok == false
		and invokeResults[3].name == "LifecycleStaleRevision")
	check("stale revision rolls staged effects back", #commits == 3 and rollbacks[1] == "bow")
	check("stale revision records a diagnostic", #diagnostics:findByName("LifecycleStaleRevision") >= 1)

	invokeAsync(4, "axe")
	runtimeSched.advance(5)
	check("async action times out via contract policy", invokeResults[4] ~= nil and invokeResults[4].name == "ActionTimeout")

	runtimeSched.spawn(handlerThreads.axe)
	check("timed-out handler cannot commit", #commits == 3)
	check("commit-boundary cancellation is recorded", #diagnostics:findByName("ActionCancelled") == 1)

	invokeAsync(5, "lance")
	runtimeSched.spawn(handlerThreads.lance)
	check("gate recovers after timeout", invokeResults[5] ~= nil and invokeResults[5].ok == true and commits[4] == "lance")

	local destroyDiag = Contracts.diagnostics()
	local rejectSystem = Contracts.system("RejectService")
		:action("Reserve", {
			input = Contracts.object({}, { allowExtra = false }),
			async = {
				concurrency = "reject",
				timeoutSeconds = false,
			},
		})
	local rejectSched = ManualScheduler.new()
	local rejectRuntime = Contracts.runtime(rejectSystem, {
		diagnostics = destroyDiag,
		scheduler = rejectSched,
	})
	local rejectThreads = {}
	rejectRuntime:implement("Reserve", function(scope)
		table.insert(rejectThreads, coroutine.running())
		coroutine.yield()
		return nil
	end)

	local rejectResults = {}
	local actor = { UserId = 99 }
	rejectSched.spawn(function()
		rejectResults[1] = rejectRuntime:invoke("Reserve", { payload = {}, actor = actor })
	end)
	rejectSched.spawn(function()
		rejectResults[2] = rejectRuntime:invoke("Reserve", { payload = {}, actor = actor })
	end)
	check("reject policy returns ActionBusy for in-flight duplicates", rejectResults[2] ~= nil
		and rejectResults[2].name == "ActionBusy")
	check("reject policy records ActionBusy diagnostic", #destroyDiag:findByName("ActionBusy") == 1)

	rejectSched.spawn(rejectThreads[1])
	check("original call still completes after rejection", rejectResults[1] ~= nil and rejectResults[1].ok == true)

	test:section("Async action declarations")

	local described = Inventory:actionOptions("GrantItem")
	check("actionOptions exposes async policy", described.async ~= nil and described.async.timeoutSeconds == 5)
	check("sync actions have no async policy", Contracts.system("Plain")
		:action("Noop", { input = Contracts.any() })
		:actionOptions("Noop").async == nil)

	local okBadConcurrency = pcall(function()
		Contracts.system("Bad"):action("Nope", {
			input = Contracts.any(),
			async = {
				concurrency = "parallel",
			},
		})
	end)
	check("invalid concurrency is rejected at declaration", okBadConcurrency == false)

	local okBadTimeout = pcall(function()
		Contracts.system("Bad"):action("Nope", {
			input = Contracts.any(),
			async = {
				timeoutSeconds = -1,
			},
		})
	end)
	check("invalid timeout is rejected at declaration", okBadTimeout == false)

	local scopeSystem = Contracts.system("ScopeService")
		:action("Watch", {
			input = Contracts.any(),
			async = {
				timeoutSeconds = 1,
			},
		})
	local scopeSched = ManualScheduler.new()
	local scopeRuntime = Contracts.runtime(scopeSystem, {
		scheduler = scopeSched,
	})
	local sawCancel = {}
	local scopeThread = nil
	scopeRuntime:implement("Watch", function(scope)
		scope:onCancel(function(reason)
			table.insert(sawCancel, reason)
		end)
		sawCancel.before = scope:cancelled()
		scopeThread = coroutine.running()
		coroutine.yield()
		sawCancel.after = scope:cancelled()
		return nil
	end)

	local watchResult = nil
	scopeSched.spawn(function()
		watchResult = scopeRuntime:invoke("Watch", { payload = {} })
	end)
	scopeSched.advance(1)
	scopeSched.spawn(scopeThread)
	check("scope sees cancellation state flip", sawCancel.before == false and sawCancel.after == true)
	check("scope onCancel callbacks fire with the reason", sawCancel[1] == "timeout")
	check("watch call timed out", watchResult ~= nil and watchResult.name == "ActionTimeout")

	local destroyedRuntime = Contracts.runtime(scopeSystem, {
		scheduler = ManualScheduler.new(),
	})
	destroyedRuntime:implement("Watch", function()
		return nil
	end)
	destroyedRuntime:destroy()
	local okAfterDestroy = pcall(function()
		destroyedRuntime:invoke("Watch", { payload = {} })
	end)
	check("destroyed runtime refuses new invokes", okAfterDestroy == false)
end
