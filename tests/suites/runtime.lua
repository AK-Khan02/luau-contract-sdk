--!nocheck

local Contracts = require("../../src/Contracts")

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

	test:section("Runtime")

	local InventoryLifecycle = Contracts.lifecycle("Inventory")
		:transition("Ready", "GrantItem", "Ready")

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

	local inventory = {}
	local Contract = Contracts.system("InventoryService")
		:strictPermissions()
		:mayRead("Catalog.Items")
		:mayWrite("Player.Inventory")
		:lifecycle("Inventory", InventoryLifecycle)
		:actorPolicy("admin", function(actor)
			return actor ~= nil and actor.IsAdmin == true or "admin only"
		end)
		:postcondition("InventoryContainsGrantedItem", function(context)
			return context.inventory[context.result.itemId] == true
		end)
		:action("GrantItem", {
			input = GrantInput,
			output = GrantResult,
			reads = { "Catalog.Items" },
			writes = { "Player.Inventory" },
			postconditions = { "InventoryContainsGrantedItem" },
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
					maxRequests = 1,
					windowSeconds = 10,
					key = "payload.ItemId",
				},
			},
		})

	local sessions = {
		Admin = Contract:lifecycleSession({ Inventory = "Ready" }),
		User = Contract:lifecycleSession({ Inventory = "Ready" }),
	}

	local diagnostics = Contracts.diagnostics()
	local runtime = Contracts.runtime(Contract, {
		diagnostics = diagnostics,
		sessions = {
			inventory = function(request)
				return sessions[request.actor.Name]
			end,
		},
	})

	check("runtime constructor exports module", Contracts.Runtime ~= nil and runtime:system() == Contract)
	check("runtime exposes diagnostics", runtime:diagnostics() == diagnostics)

	local invalidRuntimeOk = pcall(function()
		Contracts.runtime({
			hasAction = function()
				return true
			end,
			runAction = function() end,
		})
	end)
	check("runtime rejects partial system-shaped tables", invalidRuntimeOk == false)

	local missingImplementationOk = pcall(function()
		runtime:invoke("GrantItem", {})
	end)
	check("runtime fails loudly for missing implementation", missingImplementationOk == false)

	local unknownImplementationOk = pcall(function()
		runtime:implement("UnknownAction", function() end)
	end)
	check("runtime rejects unknown action implementations", unknownImplementationOk == false)

	local seenRequest = nil
	runtime:implement("GrantItem", function(scope, request)
		seenRequest = request
		local itemId = scope:read("Catalog.Items", function(context)
			return context.payload.ItemId
		end)

		return scope:write("Player.Inventory", function(context)
			context.inventory[itemId] = true
			return {
				granted = true,
				itemId = itemId,
			}
		end)
	end)

	local duplicateImplementationOk = pcall(function()
		runtime:implement("GrantItem", function() end)
	end)
	check("runtime protects duplicate implementations", duplicateImplementationOk == false)

	local admin = {
		Name = "Admin",
		UserId = 1,
		IsAdmin = true,
	}
	local directResult = runtime:invoke("GrantItem", {
		actor = admin,
		payload = {
			ItemId = "Rifle",
			Revision = 0,
		},
		context = {
			inventory = inventory,
		},
		sessionName = "inventory",
		revision = "Revision",
	})

	check("runtime invokes action through system runner", directResult.ok == true and directResult.value.itemId == "Rifle")
	check("runtime handler receives normalized request", seenRequest.action == "GrantItem" and seenRequest.actor == admin)
	check("runtime resolves named lifecycle session", sessions.Admin:revision() == 1)
	check("runtime action records scoped effects", #directResult.effects == 2 and directResult.effects[2].kind == "write")

	local missingSession = runtime:invoke("GrantItem", {
		actor = admin,
		payload = {
			ItemId = "Bow",
			Revision = 1,
		},
		context = {
			inventory = inventory,
		},
		sessionName = "missing",
	})
	check("runtime reports missing named session", missingSession.ok == false and missingSession.name == "LifecycleSessionMissing")
	check("runtime records missing named session", diagnostics:last().name == "LifecycleSessionMissing")

	local remoteFunction = {}
	local remoteSession = Contract:lifecycleSession({ Inventory = "Ready" })
	runtime:session("remoteInventory", remoteSession)
	runtime:bindRemote("GrantItem", remoteFunction, {
		sessions = {
			inventory = function()
				return remoteSession
			end,
		},
		context = {
			inventory = inventory,
		},
	})

	local remoteResult = remoteFunction.OnServerInvoke(admin, {
		ItemId = "Shield",
		Revision = 0,
	})
	check("runtime binds remote to registered action implementation", remoteResult ~= nil and remoteResult.itemId == "Shield")
	check("runtime remote commits lifecycle session", remoteSession:revision() == 1)

	local user = {
		Name = "User",
		UserId = 2,
		IsAdmin = false,
	}
	local rejected = remoteFunction.OnServerInvoke(user, {
		ItemId = "Potion",
		Revision = 0,
	})
	check("runtime remote enforces actor policy", rejected == nil and diagnostics:last().name == "RemoteActorRejected")

	local limited = remoteFunction.OnServerInvoke(admin, {
		ItemId = "Shield",
		Revision = 1,
	})
	check("runtime remote enforces rate limits", limited == nil and diagnostics:last().name == "RemoteRateLimited")

	local BadResponseContract = Contracts.system("BadResponseService")
		:action("BadPing", {
			input = Contracts.object({}, {
				allowExtra = false,
			}),
			remote = {
				name = "BadPing",
				direction = "server",
				response = Contracts.object({
					ok = Contracts.boolean(),
				}, {
					allowExtra = false,
				}),
			},
		})

	local badResponseDiagnostics = Contracts.diagnostics()
	local badRuntime = Contracts.runtime(BadResponseContract, {
		diagnostics = badResponseDiagnostics,
	})
	badRuntime:implement("BadPing", function()
		return {
			ok = "yes",
		}
	end)

	local badRemote = {}
	badRuntime:bindRemote("BadPing", badRemote)
	local badResponse = badRemote.OnServerInvoke(admin, {})
	check("runtime remote validates response schema", badResponse == nil and badResponseDiagnostics:last().name == "RemoteResponseInvalid")

	local LegacyContract = Contracts.system("LegacyService")
		:remote("Ping", Contracts.object({}, {
			allowExtra = false,
		}), {
			response = Contracts.object({
				ok = Contracts.boolean(),
			}, {
				allowExtra = false,
			}),
		})
	local legacyRuntime = Contracts.runtime(LegacyContract)
	local legacyRemote = {}
	legacyRuntime:bindRemotes({
		Ping = legacyRemote,
	}, {
		handler = function()
			return {
				ok = true,
			}
		end,
	})
	check("runtime binds non-action remotes with explicit handler", legacyRemote.OnServerInvoke(admin, {}).ok == true)

	local description = runtime:describe()
	check("runtime report lists implementations", description.implementedActions[1] == "GrantItem")
	check("runtime report lists bound remotes", description.boundRemotes[1] == "GrantItem")
	check("runtime report lists sessions", #description.sessions == 2)
	check("runtime report hides functions", containsFunction(description) == false)

	runtime:destroy()
	check("runtime destroy disconnects remote functions", remoteFunction.OnServerInvoke == nil)
	check("runtime report marks destroyed state", runtime:describe().destroyed == true)

	local invokeAfterDestroyOk = pcall(function()
		runtime:invoke("GrantItem", {})
	end)
	check("runtime rejects invokes after destroy", invokeAfterDestroyOk == false)
end
