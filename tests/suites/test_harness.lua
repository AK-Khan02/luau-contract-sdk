--!nocheck

local Contracts = require("../../src/Contracts")

return function(test)
	local function check(name, condition)
		test:check(name, condition)
	end

	test:section("RemoteTestHarness")

	local Contract = Contracts.system("HarnessInventory")
		:action("GrantItem", {
			input = Contracts.object({
				ItemId = Contracts.stringId(),
			}, {
				allowExtra = false,
			}),
			remote = {
				name = "GrantItem",
				direction = "server",
			},
			policy = {
				actorRequired = true,
			},
		})

	local harness = Contracts.Test.remoteHarness(Contract, {
		defaultResponses = {
			GrantItem = {
				ok = true,
			},
		},
	})

	check("contracts export test harness", Contracts.Test.RemoteHarness ~= nil)

	harness:implement("GrantItem")
	harness:bind("GrantItem")

	harness:call("GrantItem", {
		UserId = 1,
	}, {
		ItemId = 123,
	})

	check("remote harness rejects invalid payload before handler", harness:handlerCalls("GrantItem") == 0)
	check("remote harness exposes diagnostics", harness:lastDiagnostic().name == "ActionInputInvalid")

	harness:clearDiagnostics()
	harness:call("GrantItem", nil, {
		ItemId = "Sword",
	})

	check("remote harness rejects missing actor before handler", harness:handlerCalls("GrantItem") == 0)
	check("remote harness records actor failure", string.find(harness:lastDiagnostic().name, "Actor", 1, true) ~= nil)

	harness:clearDiagnostics()
	harness:call("GrantItem", {
		UserId = 1,
	}, {
		ItemId = "Sword",
	})

	check("remote harness runs handler for valid calls", harness:handlerCalls("GrantItem") == 1)
	check("remote harness clears diagnostics", harness:lastDiagnostic() == nil)
end
