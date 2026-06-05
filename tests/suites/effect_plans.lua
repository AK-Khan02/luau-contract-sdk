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

	test:section("EffectPlans")

	local GrantInput = Contracts.object({
		ItemId = Contracts.stringId(),
	}, {
		allowExtra = false,
	})

	local GrantOutput = Contracts.object({
		granted = Contracts.boolean(),
		itemId = Contracts.stringId(),
	}, {
		allowExtra = false,
	})

	local inventory = {}
	local Inventory = Contracts.system("TransactionalInventory")
		:strictPermissions()
		:mayWrite("Player.Inventory")
		:postcondition("PlansInventoryWrite", function(context)
			return context.effects:has({
				kind = "write",
				target = "Player.Inventory",
				itemId = context.result.itemId,
			})
		end)
		:postcondition("AlwaysFails", function()
			return false
		end)
		:action("GrantItem", {
			input = GrantInput,
			output = GrantOutput,
			writes = { "Player.Inventory" },
			postconditions = { "PlansInventoryWrite" },
		})
		:action("BadOutputGrant", {
			input = GrantInput,
			output = GrantOutput,
			writes = { "Player.Inventory" },
		})
		:action("RejectedGrant", {
			input = GrantInput,
			output = GrantOutput,
			writes = { "Player.Inventory" },
			postconditions = { "AlwaysFails" },
		})
		:action("CommitFails", {
			input = GrantInput,
			output = GrantOutput,
			writes = { "Player.Inventory" },
		})

	local success = Inventory:runAction("GrantItem", {
		payload = {
			ItemId = "Rifle",
		},
		context = {
			inventory = inventory,
		},
	}, function(scope)
		local itemId = scope:payload().ItemId
		scope:stageWrite("Player.Inventory", {
			metadata = {
				audit = function() end,
				itemId = itemId,
			},
			commit = function(context)
				context.inventory[itemId] = true
				return {
					undo = function() end,
				}
			end,
			rollback = function(context)
				context.inventory[itemId] = nil
			end,
		})

		return {
			granted = true,
			itemId = itemId,
		}
	end)

	check("staged action commits after postconditions", success.ok == true and inventory.Rifle == true)
	check("staged action reports committed effect", success.effects[1].status == "committed" and success.commit.committed == 1)
	check("staged action reports hide functions", containsFunction(success.effects) == false and containsFunction(success.commit) == false)
	check("staged action report sanitizes metadata and results", success.effects[1].metadata.audit.kind == "function" and success.effects[1].result.undo.kind == "function")

	local invalidOutputRan = false
	local invalidOutput = Inventory:runAction("BadOutputGrant", {
		payload = {
			ItemId = "Bow",
		},
		context = {
			inventory = inventory,
		},
	}, function(scope)
		scope:stageWrite("Player.Inventory", function(context)
			invalidOutputRan = true
			context.inventory.Bow = true
		end)

		return {
			granted = true,
			item = "Bow",
		}
	end)

	check("invalid output prevents staged commit", invalidOutput.ok == false and invalidOutputRan == false and inventory.Bow ~= true)
	check("invalid output keeps staged effect planned", invalidOutput.effects[1].status == "planned")

	local rejectedCommitRan = false
	local rejected = Inventory:runAction("RejectedGrant", {
		payload = {
			ItemId = "Potion",
		},
		context = {
			inventory = inventory,
		},
	}, function(scope)
		scope:stageWrite("Player.Inventory", function(context)
			rejectedCommitRan = true
			context.inventory.Potion = true
		end)

		return {
			granted = true,
			itemId = "Potion",
		}
	end)

	check("postcondition failure prevents staged commit", rejected.ok == false and rejectedCommitRan == false and inventory.Potion ~= true)

	local rollbackLog = {}
	local commitDiagnostics = Contracts.diagnostics()
	local failedCommit = Inventory:runAction("CommitFails", {
		payload = {
			ItemId = "Shield",
		},
		context = {
			inventory = inventory,
		},
		diagnostics = commitDiagnostics,
	}, function(scope)
		scope:stageWrite("Player.Inventory", {
			metadata = {
				itemId = "Axe",
			},
			commit = function(context)
				table.insert(rollbackLog, "commit Axe")
				context.inventory.Axe = true
			end,
			rollback = function(context)
				table.insert(rollbackLog, "rollback Axe")
				context.inventory.Axe = nil
			end,
		})

		scope:stageWrite("Player.Inventory", {
			metadata = {
				itemId = "Shield",
			},
			commit = function()
				table.insert(rollbackLog, "commit Shield")
				error("cannot grant shield")
			end,
		})

		return {
			granted = true,
			itemId = "Shield",
		}
	end)

	check("commit failure fails action", failedCommit.ok == false and failedCommit.name == "ActionCommitFailed")
	check("commit failure rolls back prior committed effects", inventory.Axe ~= true and rollbackLog[2] == "commit Shield" and rollbackLog[3] == "rollback Axe")
	check("commit failure records diagnostic", commitDiagnostics:last().name == "ActionCommitFailed")
	check("commit failure reports statuses", failedCommit.effects[1].status == "rolledBack" and failedCommit.effects[2].status == "failed")

	local BrokenLifecycle = Contracts.lifecycle("Match")
		:transition("Running", "RoundEnded", "Results")

	local lifecycleInventory = {}
	local Match = Contracts.system("TransactionalMatch")
		:strictPermissions()
		:mayWrite("Match.Rewards")
		:lifecycle("Match", BrokenLifecycle)
		:action("BadEmit", {
			output = GrantOutput,
			writes = { "Match.Rewards" },
			lifecycle = {
				requires = {
					Match = "Running",
				},
				emits = {
					Match = "RoundStarted",
				},
			},
		})

	local lifecycleCommitRan = false
	local lifecycleFailure = Match:runAction("BadEmit", {
		payload = {
			ItemId = "Gem",
		},
		states = {
			Match = "Running",
		},
		context = {
			inventory = lifecycleInventory,
		},
	}, function(scope)
		scope:stageWrite("Match.Rewards", function(context)
			lifecycleCommitRan = true
			context.inventory.Gem = true
		end)

		return {
			granted = true,
			itemId = "Gem",
		}
	end)

	check("lifecycle transition failure prevents staged commit", lifecycleFailure.ok == false and lifecycleCommitRan == false and lifecycleInventory.Gem ~= true)
	check("lifecycle transition failure leaves staged effect planned", lifecycleFailure.effects[1].status == "planned")

	local StaleLifecycle = Contracts.lifecycle("Match")
		:transition("Lobby", "RoundStarted", "Running")
		:transition("Running", "RoundEnded", "Results")

	local StaleMatch = Contracts.system("TransactionalSessionMatch")
		:strictPermissions()
		:mayWrite("Match.Rewards")
		:lifecycle("Match", StaleLifecycle)
		:action("GrantOnStart", {
			output = GrantOutput,
			writes = { "Match.Rewards" },
			lifecycle = {
				requires = {
					Match = "Lobby",
				},
				emits = {
					Match = "RoundStarted",
				},
			},
		})
		:action("ExternalStart", {
			output = Contracts.literal("started"),
			lifecycle = {
				requires = {
					Match = "Lobby",
				},
				emits = {
					Match = "RoundStarted",
				},
			},
		})

	local staleInventory = {}
	local staleSession = StaleMatch:lifecycleSession({
		Match = "Lobby",
	})
	local staleRollbackLog = {}
	local staleResult = StaleMatch:runAction("GrantOnStart", {
		context = {
			inventory = staleInventory,
		},
		session = staleSession,
	}, function(scope)
		scope:stageWrite("Match.Rewards", {
			commit = function(context)
				table.insert(staleRollbackLog, "commit")
				context.inventory.Coin = true
			end,
			rollback = function(context)
				table.insert(staleRollbackLog, "rollback")
				context.inventory.Coin = nil
			end,
		})

		local external = staleSession:apply("ExternalStart")
		check("test setup advances session before staged commit", external.ok == true)

		return {
			granted = true,
			itemId = "Coin",
		}
	end)

	check("stale lifecycle apply rolls back committed staged effects", staleResult.ok == false and staleResult.name == "LifecycleStaleRevision" and staleInventory.Coin ~= true)
	check("stale lifecycle rollback runs in result", staleRollbackLog[1] == "commit" and staleRollbackLog[2] == "rollback")
	check("stale lifecycle reports rolled back effect", staleResult.effects[1].status == "rolledBack" and staleResult.rollback.rolledBack == 1)
end
