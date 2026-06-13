--!strict

local Contracts = require("../../src/Contracts")
local RemoteGuard = require("../../src/Roblox/RemoteGuard")

return function(test)
	local function check(name, condition)
		test:check(name, condition)
	end

	test:section("LifecycleSessions")

	local MatchLifecycle = Contracts.lifecycle("Match")
		:transition("Lobby", "RoundStarted", "Running")
		:transition("Running", "RoundEnded", "Results")
		:transition("Results", "Reset", "Lobby")

	local Match = Contracts.system("MatchService")
		:lifecycle("Match", MatchLifecycle)
		:postcondition("RoundStarted", function(context)
			return context.result == "started"
		end)
		:action("StartRound", {
			output = Contracts.literal("started"),
			postconditions = { "RoundStarted" },
			lifecycle = {
				requires = {
					Match = "Lobby",
				},
				emits = {
					Match = "RoundStarted",
				},
			},
			remote = {
				name = "StartRoundRemote",
				direction = "server",
			},
		})
		:action("EndRound", {
			output = Contracts.literal("ended"),
			lifecycle = {
				requires = {
					Match = "Running",
				},
				emits = {
					Match = "RoundEnded",
				},
			},
		})
		:action("BadEmit", {
			output = Contracts.literal("bad"),
			lifecycle = {
				requires = {
					Match = "Running",
				},
				emits = {
					Match = "RoundStarted",
				},
			},
		})

	local session = Match:lifecycleSession({
		Match = "Lobby",
	})
	check("system creates lifecycle session", session:state("Match") == "Lobby" and session:revision() == 0)
	check(
		"package creates lifecycle session",
		Contracts.lifecycleSession(Match, { Match = "Lobby" }):state("Match") == "Lobby"
	)

	local initialSnapshot = session:snapshot()
	local diagnostics = Contracts.diagnostics()
	local started = Match:runAction("StartRound", {
		session = session,
		diagnostics = diagnostics,
	}, function()
		return "started"
	end)

	check("session-backed action succeeds", started.ok == true and started.value == "started")
	check("session commits transition after success", session:state("Match") == "Running" and session:revision() == 1)
	check(
		"session action result includes revision",
		started.lifecycle.previousRevision == 0 and started.lifecycle.revision == 1
	)
	check("session success avoids diagnostics", diagnostics:count() == 0)

	local duplicateDiagnostics = Contracts.diagnostics()
	local duplicate = Match:runAction("StartRound", {
		session = session,
		diagnostics = duplicateDiagnostics,
	}, function()
		return "started"
	end)
	check(
		"session rejects duplicate action in wrong state",
		duplicate.ok == false and duplicate.name == "ActionLifecycleStateInvalid"
	)
	check(
		"session records duplicate lifecycle failure",
		duplicateDiagnostics:last().name == "ActionLifecycleStateInvalid"
	)

	local staleDiagnostics = Contracts.diagnostics()
	local stale = Match:runAction("EndRound", {
		session = session,
		expectedRevision = 0,
		diagnostics = staleDiagnostics,
	}, function()
		return "ended"
	end)
	check("session rejects stale caller revision", stale.ok == false and stale.name == "LifecycleStaleRevision")
	check("session records stale revision", staleDiagnostics:last().name == "LifecycleStaleRevision")

	local invalidRevisionDiagnostics = Contracts.diagnostics()
	local invalidRevision = Match:runAction("EndRound", {
		session = session,
		expectedRevision = "old",
		diagnostics = invalidRevisionDiagnostics,
	}, function()
		return "ended"
	end)
	check(
		"session rejects invalid revision values",
		invalidRevision.ok == false and invalidRevision.name == "LifecycleRevisionInvalid"
	)
	check(
		"session records invalid revision value",
		invalidRevisionDiagnostics:last().name == "LifecycleRevisionInvalid"
	)

	local handlerFailure = Match:runAction("EndRound", {
		session = session,
	}, function()
		error("boom")
	end)
	check(
		"failed handler does not mutate session",
		handlerFailure.ok == false and session:state("Match") == "Running" and session:revision() == 1
	)

	local outputFailure = Match:runAction("EndRound", {
		session = session,
	}, function()
		return "wrong"
	end)
	check(
		"failed output validation does not mutate session",
		outputFailure.ok == false and session:state("Match") == "Running"
	)

	local transitionDiagnostics = Contracts.diagnostics()
	local invalidTransition = Match:runAction("BadEmit", {
		session = session,
		diagnostics = transitionDiagnostics,
	}, function()
		return "bad"
	end)
	check(
		"session rejects invalid emitted transition",
		invalidTransition.ok == false and invalidTransition.name == "ActionLifecycleTransitionInvalid"
	)
	check(
		"invalid emitted transition leaves state unchanged",
		session:state("Match") == "Running" and session:revision() == 1
	)

	local ended = Match:runAction("EndRound", {
		session = session,
		expectedRevision = 1,
	}, function()
		return "ended"
	end)
	check(
		"session accepts current revision",
		ended.ok == true and session:state("Match") == "Results" and session:revision() == 2
	)
	check("session history records transitions", #session:describe().history == 2)

	session:restore(initialSnapshot)
	check(
		"session restores snapshot",
		session:state("Match") == "Lobby" and session:revision() == 0 and #session:describe().history == 0
	)

	test:section("RemoteLifecycleSessions")

	local remoteSession = Match:lifecycleSession({
		Match = "Lobby",
	})
	local connectedHandler: ((any, any) -> any)? = nil
	local fakeRemote = {
		OnServerEvent = {
			Connect = function(_, handler)
				connectedHandler = handler
				return {
					Disconnect = function() end,
				}
			end,
		},
	}

	RemoteGuard.connect(Match, "StartRoundRemote", fakeRemote, function(_player, _payload, _scope)
		return "started"
	end, {
		session = remoteSession,
	})

	local remoteResult =
		assert(connectedHandler, "expected RemoteGuard to connect shared session handler")("PlayerA", {})
	check(
		"remote guard commits shared lifecycle session",
		remoteResult == "started" and remoteSession:state("Match") == "Running"
	)

	local playerSessions = {
		PlayerA = Match:lifecycleSession({ Match = "Lobby" }),
	}
	local sessionForHandler: ((any, any) -> any)? = nil
	local fakeSessionForRemote = {
		OnServerEvent = {
			Connect = function(_, handler)
				sessionForHandler = handler
				return {
					Disconnect = function() end,
				}
			end,
		},
	}

	RemoteGuard.connect(Match, "StartRoundRemote", fakeSessionForRemote, function(_player, _payload, _scope)
		return "started"
	end, {
		sessionFor = function(player)
			return playerSessions[player]
		end,
		revision = function(player)
			return playerSessions[player]:revision()
		end,
	})

	local perPlayerResult =
		assert(sessionForHandler, "expected RemoteGuard to connect per-player session handler")("PlayerA", {})
	check(
		"remote guard resolves per-player lifecycle session",
		perPlayerResult == "started" and playerSessions.PlayerA:state("Match") == "Running"
	)

	local revisionErrorHandler: ((any, any) -> any)? = nil
	local fakeRevisionErrorRemote = {
		OnServerEvent = {
			Connect = function(_, handler)
				revisionErrorHandler = handler
				return {
					Disconnect = function() end,
				}
			end,
		},
	}
	local revisionErrorDiagnostics = Contracts.diagnostics()
	local revisionErrorRan = false
	RemoteGuard.connect(Match, "StartRoundRemote", fakeRevisionErrorRemote, function()
		revisionErrorRan = true
		return "started"
	end, {
		session = Match:lifecycleSession({ Match = "Lobby" }),
		diagnostics = revisionErrorDiagnostics,
		revision = function()
			error("revision failed")
		end,
	})

	local revisionErrorResult =
		assert(revisionErrorHandler, "expected RemoteGuard to connect revision error handler")("PlayerA", {})
	check("remote guard aborts failed revision resolver", revisionErrorResult == nil and revisionErrorRan == false)
	check(
		"remote guard records failed revision resolver",
		revisionErrorDiagnostics:last().name == "LifecycleRevisionError"
	)
end
