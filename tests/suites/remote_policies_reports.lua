--!nocheck

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
					key = "payload.ItemId",
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
	RemoteGuard.connect(Contract, "GrantItem", remoteFunction, function(player, payload, scope)
		return scope:write("Player.Inventory", function()
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
	check("remote actor policy rejects unauthorized caller", rejected == nil and diagnostics:last().name == "RemoteActorRejected")
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
	check("remote lifecycle policy requires named session resolver", missingSessionResult == nil and missingSessionRan == false)
	check("remote lifecycle missing resolver is diagnosed", missingSessionDiagnostics:last().name == "LifecycleSessionMissing")

	local ResponseContract = Contracts.system("ResponseService")
		:remote("GetStatus", Contracts.object({}, {
			allowExtra = false,
		}), {
			direction = "server",
			response = Contracts.object({
				ok = Contracts.boolean(),
			}, {
				allowExtra = false,
			}),
		})

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

	local ClientContract = Contracts.system("ClientNotifications")
		:remote("Notify", Contracts.any(), {
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

	test:section("StableReports")

	local report = Contract:describe()
	check("system report has stable format version", report.formatVersion == 1)
	check("system report has canonical permission fields", report.permissions.mayWrite[1] == "Player.Inventory")
	check("system report includes named actor policies", report.actorPolicies[1] == "admin")
	check("system report serializes action input schema", report.actions.GrantItem.input.shape.ItemId.kind == "string")
	check("system report serializes remote response schema", report.remotes.GrantItem.response.shape.granted.kind == "boolean")
	check("system report serializes remote actor metadata", report.remotes.GrantItem.actor == "admin")
	check("system report serializes lifecycle guard metadata", report.remotes.GrantItem.lifecycle.session == "inventory")
	check("system report serializes rate limit metadata", report.remotes.GrantItem.rateLimit.key == "payload.ItemId")
	check("system report serializes lifecycle definitions", report.lifecycles.Inventory.transitions.Ready.GrantItem == "Ready")
	check("system report does not expose functions", containsFunction(report) == false)

	local CustomContract = Contracts.system("CustomReport")
		:remote("Custom", Contracts.custom("safeCustom", function()
			return true
		end))
	local customReport = CustomContract:describe()
	check("custom schemas report by name", customReport.remotes.Custom.payload.kind == "custom" and customReport.remotes.Custom.payload.name == "safeCustom")
	check("custom schema report hides validator", containsFunction(customReport) == false)

	local studioReport = Contracts.Studio.StudioReport.fromContracts({ Contract })
	check("studio report consumes contract reports", studioReport.summary.contractCount == 1 and studioReport.contracts[1].name == "InventoryService")
end
