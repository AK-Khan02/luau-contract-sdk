--!nonstrict

local Contracts = require("../../src/Contracts")
local ManualScheduler = require("../../src/Test/ManualScheduler")

local function buildSystem()
	return Contracts.system("MiddlewareService")
		:action("Grant", {
			input = Contracts.object({
				id = Contracts.stringId(),
			}, { allowExtra = false }),
			output = Contracts.object({
				granted = Contracts.boolean(),
			}, { allowExtra = false }),
		})
		:action("Slow", {
			input = Contracts.any(),
			async = {
				timeoutSeconds = 5,
				concurrency = "serialize",
			},
		})
end

local function buildRuntime(scheduler, diagnostics)
	local runtime = Contracts.runtime(buildSystem(), {
		scheduler = scheduler or ManualScheduler.new(),
		diagnostics = diagnostics or Contracts.diagnostics(),
	})
	runtime:implement("Grant", function()
		return { granted = true }
	end)
	return runtime
end

return function(test)
	local function check(name, condition)
		test:check(name, condition)
	end

	test:section("Action taps")

	local sched = ManualScheduler.new(100)
	local runtime = buildRuntime(sched)

	local events = {}
	local off = runtime:onAction({
		started = function(event)
			table.insert(events, { phase = "started", event = event })
		end,
		settled = function(event)
			table.insert(events, { phase = "settled", event = event })
		end,
	})

	local actor = { UserId = 1 }
	local result = runtime:invoke("Grant", { payload = { id = "Sword" }, actor = actor })
	check(
		"direct invoke fires started then settled",
		#events == 2 and events[1].phase == "started" and events[2].phase == "settled"
	)
	check(
		"started event carries identity fields",
		events[1].event.action == "Grant" and events[1].event.actor == actor and events[1].event.remote == nil
	)
	check("non-gated startedAt equals queuedAt", events[1].event.startedAt == events[1].event.queuedAt)
	check(
		"settled event reports the outcome",
		events[2].event.ok == true and events[2].event.outcome == "Grant" and events[2].event.result == result
	)
	check("settled event timestamps are ordered", events[2].event.settledAt >= events[2].event.startedAt)

	events = {}
	runtime:invoke("Grant", { payload = { id = 123 }, actor = actor })
	check(
		"validation failures inside runAction still settle",
		#events == 2 and events[2].event.ok == false and events[2].event.outcome == "ActionInputInvalid"
	)

	off()
	events = {}
	runtime:invoke("Grant", { payload = { id = "Sword" }, actor = actor })
	check("unsubscribed taps stop firing", #events == 0)

	local dropDiag = Contracts.diagnostics()
	local dropRuntime = buildRuntime(ManualScheduler.new(), dropDiag)
	local dropCalls = 0
	dropRuntime:onAction({
		settled = function()
			dropCalls += 1
			error("listener boom")
		end,
	})
	dropRuntime:invoke("Grant", { payload = { id = "A" }, actor = actor })
	dropRuntime:invoke("Grant", { payload = { id = "B" }, actor = actor })
	check("throwing listeners are dropped after first failure", dropCalls == 1)

	test:section("Taps with async gate")

	local gateSched = ManualScheduler.new(0)
	local gateRuntime = buildRuntime(gateSched)
	local slowThreads = {}
	gateRuntime:implement("Slow", function(_scope)
		table.insert(slowThreads, coroutine.running())
		coroutine.yield()
		return nil
	end)

	local gateEvents = {}
	gateRuntime:onAction({
		started = function(event)
			table.insert(gateEvents, "started:" .. tostring(event.startedAt))
		end,
		settled = function(event)
			table.insert(gateEvents, "settled:" .. tostring(event.outcome))
		end,
	})

	local slowResults = {}
	gateSched.spawn(function()
		slowResults[1] = gateRuntime:invoke("Slow", { payload = {}, actor = actor })
	end)
	check("gated call fires started on acquire", gateEvents[1] == "started:0")

	gateSched.advance(1)
	gateSched.spawn(function()
		slowResults[2] = gateRuntime:invoke("Slow", { payload = {}, actor = actor })
	end)
	check("queued call has not started", #gateEvents == 1 and #slowThreads == 1)

	gateSched.spawn(slowThreads[1])
	-- Lock release resumes the queued caller before the first caller's pipeline
	-- unwinds, so the queued call's started event precedes the first settled.
	check("queued call starts on release with later startedAt", gateEvents[2] == "started:1")
	check("first gated call settles ok", gateEvents[3] == "settled:Slow")
	gateSched.spawn(slowThreads[2])
	check("queued call settles", gateEvents[4] == "settled:Slow")
	check("gated calls return action results", slowResults[1].ok == true and slowResults[2].ok == true)

	-- Reject path: settled fires without started.
	local rejectSystem = Contracts.system("RejectTap"):action("Hold", {
		input = Contracts.any(),
		async = {
			timeoutSeconds = false,
			concurrency = "reject",
		},
	})
	local rejectSched = ManualScheduler.new()
	local rejectRuntime = Contracts.runtime(rejectSystem, { scheduler = rejectSched })
	local holdThread = nil
	rejectRuntime:implement("Hold", function()
		holdThread = coroutine.running()
		coroutine.yield()
		return nil
	end)

	local rejectEvents = {}
	rejectRuntime:onAction({
		started = function()
			table.insert(rejectEvents, "started")
		end,
		settled = function(event)
			table.insert(rejectEvents, "settled:" .. tostring(event.outcome) .. ":" .. tostring(event.startedAt))
		end,
	})

	rejectSched.spawn(function()
		rejectRuntime:invoke("Hold", { payload = {}, actor = actor })
	end)
	rejectSched.spawn(function()
		rejectRuntime:invoke("Hold", { payload = {}, actor = actor })
	end)
	check("busy rejection settles without started", rejectEvents[2] == "settled:ActionBusy:nil")
	rejectSched.spawn(holdThread)

	test:section("Wrap middleware outcome matrix")

	local wrapDiag = Contracts.diagnostics()
	local wrapRuntime = buildRuntime(ManualScheduler.new(), wrapDiag)

	local seen = {}
	local removePassthrough = wrapRuntime:use(function(ctx, next)
		table.insert(seen, "outer:" .. ctx.action)
		ctx.locals.touchedByOuter = true
		return next()
	end)
	wrapRuntime:use(function(ctx, next)
		table.insert(seen, "inner:" .. tostring(ctx.locals.touchedByOuter))
		return next()
	end)

	local passResult = wrapRuntime:invoke("Grant", { payload = { id = "Sword" }, actor = actor })
	check("wraps run outermost-first and share locals", seen[1] == "outer:Grant" and seen[2] == "inner:true")
	check("passthrough returns the genuine result", passResult.ok == true and passResult.value.granted == true)
	check(
		"ctx exposes raw payload for direct invoke",
		(function()
			local sawValidated = nil
			local remove = wrapRuntime:use(function(ctx, next)
				sawValidated = ctx.validated
				return next()
			end)
			wrapRuntime:invoke("Grant", { payload = { id = "Sword" }, actor = actor })
			remove()
			return sawValidated == false
		end)()
	)

	removePassthrough()
	seen = {}
	wrapRuntime:invoke("Grant", { payload = { id = "Sword" }, actor = actor })
	check("removed wraps stop running", seen[1] == "inner:nil")

	local failRuntime = buildRuntime(ManualScheduler.new(), wrapDiag)
	local handlerRan = false
	failRuntime:implement("Grant", function()
		handlerRan = true
		return { granted = true }
	end, { overwrite = true })
	failRuntime:use(function(ctx, next)
		return ctx:fail("ServerOverloaded", "shed load")
	end)
	local failResult = failRuntime:invoke("Grant", { payload = { id = "Sword" }, actor = actor })
	check(
		"ctx:fail short-circuits without running the action",
		failResult.ok == false and failResult.name == "ServerOverloaded" and handlerRan == false
	)
	test:expectMatch(
		"ctx:fail records a diagnostic with the reason",
		wrapDiag:findByName("ServerOverloaded")[1].message,
		"shed load"
	)

	local asyncVetoSystem = Contracts.system("AsyncVeto"):action("Save", {
		input = Contracts.any(),
		async = {
			timeoutSeconds = false,
		},
	})
	local asyncVetoRuntime = Contracts.runtime(asyncVetoSystem)
	local asyncHandlerRan = false
	asyncVetoRuntime:implement("Save", function()
		asyncHandlerRan = true
		return nil
	end)
	asyncVetoRuntime:use(function(ctx, next)
		return ctx:fail("MaintenanceMode", "paused")
	end)
	local asyncVeto = asyncVetoRuntime:invoke("Save", { payload = {}, actor = actor })
	check(
		"async middleware veto does not require scheduler",
		asyncVeto.ok == false and asyncVeto.name == "MaintenanceMode" and asyncHandlerRan == false
	)

	local throwRuntime = buildRuntime(ManualScheduler.new(), wrapDiag)
	throwRuntime:use(function()
		error("middleware boom")
	end)
	local thrown = throwRuntime:invoke("Grant", { payload = { id = "Sword" }, actor = actor })
	check(
		"throwing middleware yields ActionMiddlewareError",
		thrown.ok == false and thrown.name == "ActionMiddlewareError"
	)
	test:expectMatch(
		"middleware error diagnostic carries the message",
		wrapDiag:findByName("ActionMiddlewareError")[1].message,
		"middleware boom"
	)

	local forgeRuntime = buildRuntime(ManualScheduler.new(), wrapDiag)
	forgeRuntime:use(function(_ctx, next)
		next()
		return { ok = true, name = "Forged", value = { granted = true } }
	end)
	local forged = forgeRuntime:invoke("Grant", { payload = { id = "Sword" }, actor = actor })
	check("forged results are rejected", forged.ok == false and forged.name == "ActionMiddlewareInvalidResult")

	local nilRuntime = buildRuntime(ManualScheduler.new(), wrapDiag)
	nilRuntime:use(function()
		return nil
	end)
	local nilResult = nilRuntime:invoke("Grant", { payload = { id = "Sword" }, actor = actor })
	check("nil without next is rejected", nilResult.ok == false and nilResult.name == "ActionMiddlewareInvalidResult")

	local doubleRuntime = buildRuntime(ManualScheduler.new(), wrapDiag)
	doubleRuntime:use(function(_ctx, next)
		next()
		return next()
	end)
	local doubled = doubleRuntime:invoke("Grant", { payload = { id = "Sword" }, actor = actor })
	check(
		"double next() becomes ActionMiddlewareError",
		doubled.ok == false and doubled.name == "ActionMiddlewareError"
	)
	test:expectMatch("double next() error explains itself", doubled.reason, "next() already called")

	local lateFailRuntime = buildRuntime(ManualScheduler.new(), wrapDiag)
	lateFailRuntime:use(function(ctx, next)
		next()
		return ctx:fail("TooLate", "after the fact")
	end)
	local lateFail = lateFailRuntime:invoke("Grant", { payload = { id = "Sword" }, actor = actor })
	check(
		"ctx:fail after next() becomes ActionMiddlewareError",
		lateFail.ok == false and lateFail.name == "ActionMiddlewareError"
	)
	test:expectMatch("late fail error explains itself", lateFail.reason, "cannot be called after next()")

	local filterRuntime = buildRuntime(ManualScheduler.new(), wrapDiag)
	local filterCalls = 0
	filterRuntime:use(function(_ctx, next)
		filterCalls += 1
		return next()
	end, { actions = { "Other" } })
	filterRuntime:invoke("Grant", { payload = { id = "Sword" }, actor = actor })
	check("action filters skip non-matching actions", filterCalls == 0)

	test:section("Wraps on remote-bound actions")

	local remoteSystem = Contracts.system("RemoteWrapped"):action("Equip", {
		input = Contracts.object({
			id = Contracts.stringId(),
		}, { allowExtra = false }),
		remote = {
			name = "EquipRemote",
			direction = "server",
		},
	})
	local remoteDiag = Contracts.diagnostics()
	local remoteRuntime = Contracts.runtime(remoteSystem, {
		diagnostics = remoteDiag,
		scheduler = ManualScheduler.new(),
	})
	local remoteHandled = 0
	remoteRuntime:implement("Equip", function()
		remoteHandled += 1
		return nil
	end)

	local invokeRemote = nil
	local fakeRemote = {
		OnServerEvent = {
			Connect = function(_, handler)
				invokeRemote = handler
				return { Disconnect = function() end }
			end,
		},
	}
	remoteRuntime:bindRemote("EquipRemote", fakeRemote)

	local remoteSeen = {}
	remoteRuntime:use(function(ctx, next)
		table.insert(remoteSeen, {
			remote = ctx.remote,
			validated = ctx.validated,
			payload = ctx.payload,
		})
		return next()
	end)

	invokeRemote({ UserId = 9 }, { id = "Bow" })
	check("use() after bindRemote applies to remote calls", #remoteSeen == 1 and remoteHandled == 1)
	check(
		"remote ctx is validated with remote name",
		remoteSeen[1].validated == true and remoteSeen[1].remote == "EquipRemote" and remoteSeen[1].payload.id == "Bow"
	)

	local remoteVeto = remoteRuntime:use(function(ctx, next)
		return ctx:fail("MaintenanceMode", "remotes disabled")
	end)
	invokeRemote({ UserId = 9 }, { id = "Bow" })
	check("remote wrap veto blocks the handler", remoteHandled == 1)
	check("remote wrap veto records a diagnostic", #remoteDiag:findByName("MaintenanceMode") == 1)
	remoteVeto()

	-- Pre-pipeline remote failures (payload validation) bypass wraps entirely.
	remoteSeen = {}
	invokeRemote({ UserId = 9 }, { id = 123 })
	check("invalid remote payloads never reach wraps", #remoteSeen == 0 and remoteHandled == 1)

	test:section("Wraps and cancellation")

	local cancelSystem = Contracts.system("CancelWrapped"):action("Save", {
		input = Contracts.any(),
		async = {
			timeoutSeconds = false,
		},
	})
	local cancelSched = ManualScheduler.new()
	local cancelRuntime = Contracts.runtime(cancelSystem, {
		scheduler = cancelSched,
	})
	cancelRuntime:implement("Save", function()
		coroutine.yield()
		return nil
	end)

	local unwound = nil
	cancelRuntime:use(function(_ctx, next)
		local value = next()
		unwound = value.name
		return value
	end)

	local cancelActorRef = { UserId = 5 }
	local cancelResult = nil
	cancelSched.spawn(function()
		cancelResult = cancelRuntime:invoke("Save", { payload = {}, actor = cancelActorRef })
	end)
	cancelRuntime:cancelActor(cancelActorRef, "player-left")
	check(
		"force-settled cancellation unwinds through wraps",
		unwound == "ActionCancelled" and cancelResult ~= nil and cancelResult.name == "ActionCancelled"
	)
end
