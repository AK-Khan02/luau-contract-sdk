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
	test:expectMatch("timeout failure names the action and deadline", timeoutResult.reason, "GrantItem timed out after 3 seconds")
	check("timeout cancels the token", timeoutToken ~= nil and timeoutToken:isCancelled() and timeoutToken:reason() == "timeout")
	check("timeout records a diagnostic", #timeoutDiag:findByName("ActionTimeout") == 1)
	test:expectMatch("timeout diagnostic message names the action and deadline",
		timeoutDiag:findByName("ActionTimeout")[1].message, "GrantItem timed out after 3 seconds")

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

	local commitsBeforeStale = #commits
	local rollbacksBeforeStale = #rollbacks
	invokeAsync(3, "bow")
	session:restore({
		revision = session:revision() + 1,
		states = session:states(),
	})
	runtimeSched.spawn(handlerThreads.bow)
	check("stale revision after yield refuses to apply", invokeResults[3] ~= nil and invokeResults[3].ok == false
		and invokeResults[3].name == "LifecycleStaleRevision")
	check("stale revision compensates the staged commit",
		#commits == commitsBeforeStale + 1 and commits[#commits] == "bow")
	check("stale revision rolls staged effects back",
		#rollbacks == rollbacksBeforeStale + 1 and rollbacks[#rollbacks] == "bow")
	check("stale revision records a diagnostic", #diagnostics:findByName("LifecycleStaleRevision") >= 1)
	test:expectMatch("stale revision diagnostic explains expected vs current",
		diagnostics:findByName("LifecycleStaleRevision")[1].message,
		"expected revision 0 but current revision is 1")

	local commitsBeforeTimeout = #commits
	invokeAsync(4, "axe")
	runtimeSched.advance(5)
	check("async action times out via contract policy", invokeResults[4] ~= nil and invokeResults[4].name == "ActionTimeout")

	runtimeSched.spawn(handlerThreads.axe)
	check("timed-out handler cannot commit", #commits == commitsBeforeTimeout)
	check("commit-boundary cancellation is recorded", #diagnostics:findByName("ActionCancelled") == 1)
	test:expectMatch("cancellation diagnostic explains the discard",
		diagnostics:findByName("ActionCancelled")[1].message,
		"InventoryService.GrantItem was cancelled (timeout); staged effects were discarded")

	invokeAsync(5, "lance")
	runtimeSched.spawn(handlerThreads.lance)
	check("gate recovers after timeout", invokeResults[5] ~= nil and invokeResults[5].ok == true
		and commits[#commits] == "lance" and #commits == commitsBeforeTimeout + 1)

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
	test:expectMatch("busy diagnostic names the action",
		destroyDiag:findByName("ActionBusy")[1].message, "Reserve is already running for this session")

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

	test:section("Player-leave cancellation")

	local PlayerCancellation = require("../../src/Roblox/PlayerCancellation")

	local cancelSystem = Contracts.system("CancelService")
		:action("SaveLoadout", {
			input = Contracts.object({
				id = Contracts.stringId(),
			}, { allowExtra = false }),
			writes = { "PlayerData/Loadout" },
			async = {
				timeoutSeconds = false,
				concurrency = "serialize",
			},
		})

	local cancelSched = ManualScheduler.new()
	local cancelDiag = Contracts.diagnostics()
	local cancelRuntime = Contracts.runtime(cancelSystem, {
		diagnostics = cancelDiag,
		scheduler = cancelSched,
	})

	local cancelCommits = {}
	local cancelThreads = {}
	cancelRuntime:implement("SaveLoadout", function(scope)
		local id = scope:payload().id
		scope:stageWrite("PlayerData/Loadout", {
			commit = function()
				table.insert(cancelCommits, id)
			end,
		})
		cancelThreads[id] = coroutine.running()
		coroutine.yield()
		return nil
	end)

	local playerA = { UserId = 1, Name = "A" }
	local playerB = { UserId = 2, Name = "B" }
	local cancelResults = {}
	local function invokeFor(slot, player, id)
		cancelSched.spawn(function()
			cancelResults[slot] = cancelRuntime:invoke("SaveLoadout", {
				payload = { id = id },
				actor = player,
			})
		end)
	end

	check("cancelActor with no gate is a no-op", (function()
		local fresh = Contracts.runtime(cancelSystem, { scheduler = ManualScheduler.new() })
		local summary = fresh:cancelActor(playerA, "player-left")
		return summary.cancelledRuns == 0 and summary.purgedWaiters == 0
	end)())

	-- In-flight cancellation: A's first call is mid-yield, second is queued (keyed by actor).
	invokeFor(1, playerA, "alpha")
	invokeFor(2, playerA, "beta")
	invokeFor(3, playerB, "gamma")
	check("setup: A in-flight, A queued, B in-flight", cancelThreads.alpha ~= nil and cancelThreads.beta == nil
		and cancelThreads.gamma ~= nil)

	local summary = cancelRuntime:cancelActor(playerA, "player-left")
	check("cancelActor reports one run and one waiter", summary.cancelledRuns == 1 and summary.purgedWaiters == 1)
	check("in-flight run settles as ActionCancelled", cancelResults[1] ~= nil and cancelResults[1].ok == false
		and cancelResults[1].name == "ActionCancelled")
	check("queued waiter settles as ActionCancelled", cancelResults[2] ~= nil and cancelResults[2].ok == false
		and cancelResults[2].name == "ActionCancelled")
	test:expectMatch("queued waiter failure names the action and reason",
		cancelResults[2].reason, "SaveLoadout cancelled while queued (player-left)")
	check("other actors are unaffected by cancelActor", cancelResults[3] == nil and cancelThreads.gamma ~= nil)

	cancelSched.spawn(cancelThreads.alpha)
	check("zombie handler cannot commit after cancellation", #cancelCommits == 0)
	check("commit boundary records the cancellation", #cancelDiag:findByName("ActionCancelled") >= 1)

	cancelSched.spawn(cancelThreads.gamma)
	check("unrelated in-flight run still commits", cancelResults[3] ~= nil and cancelResults[3].ok == true
		and cancelCommits[1] == "gamma")

	local repeatSummary = cancelRuntime:cancelActor(playerA, "player-left")
	check("cancelActor after settle is a no-op", repeatSummary.cancelledRuns == 0 and repeatSummary.purgedWaiters == 0)

	-- Adapter wiring with a fake Players service.
	local removingHandlers = {}
	local fakePlayers = {
		PlayerRemoving = {
			Connect = function(_, handler)
				table.insert(removingHandlers, handler)
				return {
					Disconnect = function()
						removingHandlers = {}
					end,
				}
			end,
		},
	}

	local leaveHandle = PlayerCancellation.cancelOnLeave(cancelRuntime, fakePlayers)
	check("cancelOnLeave connects to PlayerRemoving", #removingHandlers == 1)

	invokeFor(4, playerB, "delta")
	check("setup: B back in flight", cancelThreads.delta ~= nil)
	removingHandlers[1](playerB)
	check("PlayerRemoving cancels that player's runs", cancelResults[4] ~= nil
		and cancelResults[4].name == "ActionCancelled")

	leaveHandle.destroy()
	leaveHandle.destroy()
	check("cancelOnLeave destroy is idempotent and disconnects", #removingHandlers == 0)

	check("cancelOnLeave validates the players service", pcall(function()
		PlayerCancellation.cancelOnLeave(cancelRuntime, {})
	end) == false)

	test:section("Timeout lock retention")

	-- A timed-out handler is still executing. Releasing the serialize lock at
	-- timeout would run the session's next action concurrently with the
	-- zombie — the double-spend race serialize exists to prevent.
	local zombieSched = ManualScheduler.new()
	local zombieGate = AsyncGate.new({ scheduler = zombieSched })
	local zombieDiag = Contracts.diagnostics()
	local zombieThread = nil
	local secondRan = false
	local zombieResults = {}

	local function runOnSession(slot, fn)
		zombieSched.spawn(function()
			zombieResults[slot] = zombieGate:run("session", {
				concurrency = "serialize",
				timeoutSeconds = 3,
				system = "ZombieService",
				action = "Save",
				diagnostics = zombieDiag,
			}, fn)
		end)
	end

	runOnSession(1, function()
		zombieThread = coroutine.running()
		coroutine.yield()
		return { ok = true, label = "late" }
	end)
	runOnSession(2, function()
		secondRan = true
		return { ok = true, label = "second" }
	end)
	check("setup: zombie in flight, second queued", zombieThread ~= nil and secondRan == false)

	zombieSched.advance(3)
	check("timeout settles the caller with ActionTimeout", zombieResults[1] ~= nil
		and zombieResults[1].name == "ActionTimeout")
	check("serialize lock is held until the zombie finishes", secondRan == false and zombieResults[2] == nil)

	zombieSched.spawn(zombieThread)
	check("queued run starts after the zombie observes cancellation", secondRan == true
		and zombieResults[2] ~= nil and zombieResults[2].ok == true)
	check("late zombie result records a diagnostic", #zombieDiag:findByName("ActionLateResult") == 1)

	test:section("cancelActor reentrancy")

	-- A cancelled caller's continuation runs synchronously and can finish other
	-- in-flight work, releasing locks while cancelActor is still purging. Every
	-- queued waiter must be purged before any continuation runs, or a release
	-- hands the lock to a waiter that was supposed to be cancelled.
	local reentrantSched = ManualScheduler.new()
	local reentrantGate = AsyncGate.new({ scheduler = reentrantSched })
	local leaver = { UserId = 10 }
	local stayer = { UserId = 11 }

	local holderThreads = {}
	local function holdLock(key)
		reentrantSched.spawn(function()
			reentrantGate:run(key, {
				concurrency = "serialize",
				actor = stayer,
			}, function()
				holderThreads[key] = coroutine.running()
				coroutine.yield()
				return { ok = true }
			end)
		end)
	end

	holdLock("loadout")
	holdLock("checkpoint")
	check("setup: both locks held by the staying actor",
		holderThreads.loadout ~= nil and holderThreads.checkpoint ~= nil)

	local leaverRuns = 0
	local leaverResults = {}
	local function queueLeaver(slot, key)
		reentrantSched.spawn(function()
			leaverResults[slot] = reentrantGate:run(key, {
				concurrency = "serialize",
				actor = leaver,
			}, function()
				leaverRuns += 1
				return { ok = true }
			end)
			for _, thread in pairs(holderThreads) do
				pcall(function()
					reentrantSched.spawn(thread)
				end)
			end
		end)
	end

	queueLeaver(1, "loadout")
	queueLeaver(2, "checkpoint")
	check("setup: leaver queued behind both locks", leaverRuns == 0
		and leaverResults[1] == nil and leaverResults[2] == nil)

	local reentrantSummary = reentrantGate:cancelActor(leaver, "player-left")
	check("purged continuations cannot start the actor's other queued runs", leaverRuns == 0)
	check("cancelActor purges queued waiters on every lock", reentrantSummary.purgedWaiters == 2)
	check("both queued calls settle as cancelled",
		leaverResults[1] ~= nil and leaverResults[1].name == "ActionCancelled"
			and leaverResults[2] ~= nil and leaverResults[2].name == "ActionCancelled")

	-- A snapshotted run can settle naturally while an earlier settle's
	-- continuation unwinds; the summary must only count runs this call
	-- actually cancelled.
	local countSched = ManualScheduler.new()
	local countGate = AsyncGate.new({ scheduler = countSched })
	local countActor = { UserId = 12 }

	local countHandlers = {}
	local countResults = {}
	local function startCounted(slot, key, other)
		countSched.spawn(function()
			countResults[slot] = countGate:run(key, {
				concurrency = "serialize",
				actor = countActor,
			}, function()
				countHandlers[slot] = coroutine.running()
				coroutine.yield()
				return { ok = true }
			end)
			if countHandlers[other] ~= nil then
				pcall(function()
					countSched.spawn(countHandlers[other])
				end)
			end
		end)
	end

	startCounted(1, "save", 2)
	startCounted(2, "teleport", 1)
	check("setup: both counted runs in flight", countHandlers[1] ~= nil and countHandlers[2] ~= nil)

	local countSummary = countGate:cancelActor(countActor, "player-left")
	local cancelledCount = 0
	local naturalCount = 0
	for slot = 1, 2 do
		local result = countResults[slot]
		if result ~= nil and result.name == "ActionCancelled" then
			cancelledCount += 1
		elseif result ~= nil and result.ok == true then
			naturalCount += 1
		end
	end
	check("continuation completes the sibling run naturally", cancelledCount == 1 and naturalCount == 1)
	check("summary counts only runs this call cancelled", countSummary.cancelledRuns == 1)

	test:section("Standalone RemoteGuard async binding")

	local RemoteGuard = require("../../src/Roblox/RemoteGuard")
	local standaloneSystem = Contracts.system("StandaloneService")
		:action("Reserve", {
			input = Contracts.object({}, { allowExtra = false }),
			async = {
				timeoutSeconds = 5,
			},
			remote = {
				name = "ReserveRemote",
				direction = "server",
			},
		})

	local standaloneSched = ManualScheduler.new()
	local standaloneDiag = Contracts.diagnostics()
	local standaloneInvoke = nil
	local standaloneRemote = {
		OnServerEvent = {
			Connect = function(_, handler)
				standaloneInvoke = handler
				return {
					Disconnect = function() end,
				}
			end,
		},
	}

	local standaloneResult = nil
	RemoteGuard.connect(standaloneSystem, "ReserveRemote", standaloneRemote, function()
		standaloneResult = "handled"
		return nil
	end, {
		diagnostics = standaloneDiag,
		scheduler = standaloneSched,
	})

	standaloneSched.spawn(function()
		standaloneInvoke({ UserId = 7 }, {})
	end)
	check("standalone connect with scheduler runs async actions", standaloneResult == "handled")
	check("standalone async call records no failures", standaloneDiag:hasFailures() == false)

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
