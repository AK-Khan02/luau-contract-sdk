--!nonstrict

local Contracts = require("../../src/Contracts")
local RemoteGuard = require("../../src/Roblox/RemoteGuard")

local function containsFunction(value, seen)
	if type(value) == "function" then
		return true
	end
	if type(value) ~= "table" then
		return false
	end

	seen = seen or {}
	if seen[value] then
		return false
	end
	seen[value] = true

	for _, child in pairs(value) do
		if containsFunction(child, seen) then
			return true
		end
	end
	return false
end

return function(test)
	local function check(name, condition)
		test:check(name, condition)
	end

	test:section("RemotePolicies")

	local InventoryLifecycle = Contracts.lifecycle("Inventory"):transition("Ready", "GrantItem", "Ready")

	local GrantInput = Contracts.object({
		ItemId = Contracts.stringId(),
		Revision = Contracts.integer(0),
	}, {
		allowExtra = false,
	})

	local GrantResult = Contracts.object({
		granted = Contracts.boolean(),
		itemId = Contracts.stringId(),
	}, {
		allowExtra = false,
	})

	local Contract = Contracts.system("InventoryService")
		:actorPolicy("admin", function(player)
			return player ~= nil and player.IsAdmin == true or "admin only"
		end)
		:mayWrite("Player.Inventory")
		:lifecycle("Inventory", InventoryLifecycle)
		:action("GrantItem", {
			input = GrantInput,
			output = GrantResult,
			writes = { "Player.Inventory" },
			lifecycle = {
				requires = {
					Inventory = "Ready",
				},
				emits = {
					Inventory = "GrantItem",
				},
			},
			remote = {
				name = "GrantItem",
				direction = "server",
				actor = "admin",
				response = GrantResult,
				lifecycle = {
					session = "inventory",
					revision = "Revision",
				},
				rateLimit = {
					maxRequests = 4,
					windowSeconds = 1,
					key = "remote",
				},
			},
		})

	local sessions = {
		Admin = Contract:lifecycleSession({
			Inventory = "Ready",
		}),
		User = Contract:lifecycleSession({
			Inventory = "Ready",
		}),
	}

	local remoteFunction = {}
	local diagnostics = Contracts.diagnostics()
	RemoteGuard.connect(Contract, "GrantItem", remoteFunction, function(_player, payload, scope)
		return scope:writeEager("Player.Inventory", function()
			return {
				granted = true,
				itemId = payload.ItemId,
			}
		end)
	end, {
		diagnostics = diagnostics,
		sessions = {
			inventory = function(player)
				return sessions[player.Name]
			end,
		},
	})

	local admin = {
		Name = "Admin",
		IsAdmin = true,
	}
	local result = remoteFunction.OnServerInvoke(admin, {
		ItemId = "Rifle",
		Revision = 0,
	})
	check("remote function returns validated action response", result ~= nil and result.itemId == "Rifle")
	check("remote policy lifecycle session commits", sessions.Admin:revision() == 1)

	local user = {
		Name = "User",
		IsAdmin = false,
	}
	local rejected = remoteFunction.OnServerInvoke(user, {
		ItemId = "Rifle",
		Revision = 0,
	})
	check(
		"remote actor policy rejects unauthorized caller",
		rejected == nil and diagnostics:last().name == "RemoteActorRejected"
	)
	check("remote actor rejection does not mutate session", sessions.User:revision() == 0)

	local missingSessionRemote = {}
	local missingSessionDiagnostics = Contracts.diagnostics()
	local missingSessionRan = false
	RemoteGuard.connect(Contract, "GrantItem", missingSessionRemote, function()
		missingSessionRan = true
	end, {
		diagnostics = missingSessionDiagnostics,
	})
	local missingSessionResult = missingSessionRemote.OnServerInvoke(admin, {
		ItemId = "Bow",
		Revision = 1,
	})
	check(
		"remote lifecycle policy requires named session resolver",
		missingSessionResult == nil and missingSessionRan == false
	)
	check(
		"remote lifecycle missing resolver is diagnosed",
		missingSessionDiagnostics:last().name == "LifecycleSessionMissing"
	)

	local ResponseContract = Contracts.system("ResponseService"):remote(
		"GetStatus",
		Contracts.object({}, {
			allowExtra = false,
		}),
		{
			direction = "server",
			response = Contracts.object({
				ok = Contracts.boolean(),
			}, {
				allowExtra = false,
			}),
		}
	)

	local statusRemote = {}
	local responseDiagnostics = Contracts.diagnostics()
	RemoteGuard.connect(ResponseContract, "GetStatus", statusRemote, function()
		return {
			ok = "yes",
		}
	end, {
		diagnostics = responseDiagnostics,
	})
	local badResponse = statusRemote.OnServerInvoke("PlayerA", {})
	check("remote response schema rejects invalid return values", badResponse == nil)
	check("remote response schema records diagnostics", responseDiagnostics:last().name == "RemoteResponseInvalid")

	local ClientContract = Contracts.system("ClientNotifications"):remote("Notify", Contracts.any(), {
		direction = "client",
	})
	local directionOk = pcall(function()
		RemoteGuard.connect(ClientContract, "Notify", {
			OnServerEvent = {
				Connect = function() end,
			},
		}, function() end)
	end)
	check("server remote guard rejects client-directed remotes", directionOk == false)

	test:section("RemoteGuard on strict instances")

	-- Real Roblox Instances error on invalid member reads (instead of returning
	-- nil) and RemoteFunction.OnServerInvoke is a write-only callback. These
	-- strict fakes mimic that, so the guard cannot regress to member-probing.
	local function strictRemoteEvent()
		local listeners = {}
		local serverEvent = {
			Connect = function(_, handler)
				table.insert(listeners, handler)
				return {
					Disconnect = function() end,
				}
			end,
		}
		local remote = setmetatable({}, {
			__index = function(_, key)
				if key == "IsA" then
					return function(_, className)
						return className == "RemoteEvent" or className == "BaseRemoteEvent"
					end
				end
				if key == "OnServerEvent" then
					return serverEvent
				end
				error(tostring(key) .. " is not a valid member of RemoteEvent", 2)
			end,
			__newindex = function(_, key)
				error("unable to assign member '" .. tostring(key) .. "' of RemoteEvent", 2)
			end,
		})
		return remote, listeners
	end

	local function strictRemoteFunction()
		local state = {}
		local remote = setmetatable({}, {
			__index = function(_, key)
				if key == "IsA" then
					return function(_, className)
						return className == "RemoteFunction"
					end
				end
				if key == "OnServerInvoke" then
					error(
						"'OnServerInvoke' is a callback member of RemoteFunction; you can only set the callback value, get is not available",
						2
					)
				end
				error(tostring(key) .. " is not a valid member of RemoteFunction", 2)
			end,
			__newindex = function(_, key, value)
				if key == "OnServerInvoke" then
					state.callback = value
					return
				end
				error("unable to assign member '" .. tostring(key) .. "' of RemoteFunction", 2)
			end,
		})
		return remote, state
	end

	local InstanceContract = Contracts.system("InstanceService")
		:remote("Ping", Contracts.object({}, { allowExtra = false }), {
			direction = "server",
		})
		:remote("Sum", Contracts.object({}, { allowExtra = false }), {
			direction = "server",
			response = Contracts.object({
				total = Contracts.number(),
			}, { allowExtra = false }),
		})

	local strictEvent, strictEventListeners = strictRemoteEvent()
	local strictEventCalls = 0
	local strictEventOk = pcall(function()
		return RemoteGuard.connect(InstanceContract, "Ping", strictEvent, function()
			strictEventCalls += 1
			return nil
		end, {})
	end)
	check("strict RemoteEvent binds without member probing", strictEventOk == true)
	check(
		"strict RemoteEvent dispatches server events",
		(function()
			if #strictEventListeners == 0 then
				return false
			end
			strictEventListeners[1]({ UserId = 1 }, {})
			return strictEventCalls == 1
		end)()
	)

	local strictFunction, strictFunctionState = strictRemoteFunction()
	local strictFunctionOk = pcall(function()
		return RemoteGuard.connect(InstanceContract, "Sum", strictFunction, function()
			return { total = 3 }
		end, {})
	end)
	check("strict RemoteFunction binds without reading OnServerInvoke", strictFunctionOk == true)
	check(
		"strict RemoteFunction handler responds",
		strictFunctionState.callback ~= nil and strictFunctionState.callback({ UserId = 1 }, {}).total == 3
	)

	-- A RemoteFunction with no response schema must still bind by class.
	local plainFunction, plainFunctionState = strictRemoteFunction()
	local plainConnection = nil
	local plainFunctionOk = pcall(function()
		plainConnection = RemoteGuard.connect(InstanceContract, "Ping", plainFunction, function()
			return nil
		end, {})
	end)
	check(
		"strict RemoteFunction without response binds by class",
		plainFunctionOk == true and plainFunctionState.callback ~= nil
	)
	check(
		"strict RemoteFunction disconnect clears the callback",
		(function()
			if plainConnection == nil then
				return false
			end
			plainConnection:Disconnect()
			return plainFunctionState.callback == nil
		end)()
	)

	test:section("RemoteGuard rate-limit hardening")

	local RateLimitContract = Contracts.system("RateLimitService")
		:remote("Fire", Contracts.object({}, { allowExtra = false }), {
			direction = "server",
			rateLimit = {
				maxRequests = 1,
				windowSeconds = 1000,
			},
		})

	-- Client-payload-derived bucket keys are chosen before validation, so they
	-- must be rejected at connect time.
	local payloadKeyOk = pcall(function()
		local rejectRemote = strictRemoteEvent()
		RemoteGuard.connect(RateLimitContract, "Fire", rejectRemote, function()
			return nil
		end, {
			rateLimit = { maxRequests = 1, key = "payload.ItemId" },
		})
	end)
	check("payload-derived rate-limit keys are rejected at connect", payloadKeyOk == false)

	local rlDiag = Contracts.diagnostics()
	local rlClockState = { now = 0 }
	local rlRemote, rlListeners = strictRemoteEvent()
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

	local rlConnection = RemoteGuard.connect(RateLimitContract, "Fire", rlRemote, function()
		return nil
	end, {
		diagnostics = rlDiag,
		playersService = fakePlayers,
		clock = function()
			return rlClockState.now
		end,
	})
	check("rate-limited remote wires PlayerRemoving", #removingHandlers == 1)

	local function rateLimitCount()
		return #rlDiag:findByName("RemoteRateLimited")
	end

	local playerOne = { UserId = 1, Name = "One" }
	rlListeners[1](playerOne, {})
	check("first call is allowed", rateLimitCount() == 0)
	rlListeners[1](playerOne, {})
	check("second call in window is rate limited", rateLimitCount() == 1)

	-- A different Instance for the same user shares the UserId bucket.
	local playerOneRejoined = { UserId = 1, Name = "OneAgain" }
	rlListeners[1](playerOneRejoined, {})
	check("same UserId shares the bucket across instances", rateLimitCount() == 2)

	-- Leaving evicts the bucket, so a returning player is not stuck.
	removingHandlers[1](playerOne)
	rlListeners[1](playerOne, {})
	check("PlayerRemoving evicts the bucket so the key resets", rateLimitCount() == 2)

	rlConnection:Disconnect()
	check("disconnect tears down the PlayerRemoving connection", #removingHandlers == 0)

	test:section("StableReports")

	local report = Contract:describe()
	check("system report has stable format version", report.formatVersion == 1)
	check("system report has canonical permission fields", report.permissions.mayWrite[1] == "Player.Inventory")
	check("system report includes named actor policies", report.actorPolicies[1] == "admin")
	check("system report serializes action input schema", report.actions.GrantItem.input.shape.ItemId.kind == "string")
	check(
		"system report serializes remote response schema",
		report.remotes.GrantItem.response.shape.granted.kind == "boolean"
	)
	check("system report serializes remote actor metadata", report.remotes.GrantItem.actor == "admin")
	check(
		"system report serializes lifecycle guard metadata",
		report.remotes.GrantItem.lifecycle.session == "inventory"
	)
	check("system report serializes rate limit metadata", report.remotes.GrantItem.rateLimit.key == "remote")
	check(
		"system report serializes lifecycle definitions",
		report.lifecycles.Inventory.transitions.Ready.GrantItem == "Ready"
	)
	check("system report does not expose functions", containsFunction(report) == false)

	local CustomContract = Contracts.system("CustomReport"):remote(
		"Custom",
		Contracts.custom("safeCustom", function()
			return true
		end)
	)
	local customReport = CustomContract:describe()
	check(
		"custom schemas report by name",
		customReport.remotes.Custom.payload.kind == "custom"
			and customReport.remotes.Custom.payload.name == "safeCustom"
	)
	check("custom schema report hides validator", containsFunction(customReport) == false)

	local studioReport = Contracts.Studio.StudioReport.fromContracts({ Contract })
	check(
		"studio report consumes contract reports",
		studioReport.summary.contractCount == 1 and studioReport.contracts[1].name == "InventoryService"
	)
end
