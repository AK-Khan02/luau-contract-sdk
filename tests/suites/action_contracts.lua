--!nocheck

local Contracts = require("../../src/Contracts")
local RemoteGuard = require("../../src/Roblox/RemoteGuard")

return function(test)
	local function check(name, condition)
		test:check(name, condition)
	end

	test:section("ActionContracts")

	local InventoryLifecycle = Contracts.lifecycle("Inventory")
		:transition("Ready", "GrantItem", "Ready")
		:transition("Locked", "Unlock", "Ready")

	local GrantItemInput = Contracts.object({
		ItemId = Contracts.stringId(),
	}, {
		allowExtra = false,
	})

	local GrantItemOutput = Contracts.object({
		granted = Contracts.boolean(),
		itemId = Contracts.stringId(),
	}, {
		allowExtra = false,
	})

	local inventory = {}
	local grantContract = Contracts.system("InventoryService")
		:mayRead("Catalog.Items")
		:mayWrite("Player.Inventory")
		:mustNeverTouch("Workspace.Map")
		:lifecycle("Inventory", InventoryLifecycle)
		:precondition("ProfileLoaded", function(context)
			return context.profileLoaded == true
		end)
		:postcondition("InventoryContainsGrantedItem", function(context)
			return context.result ~= nil and context.inventory[context.result.itemId] == true
		end)
		:action("GrantItem", {
			input = GrantItemInput,
			output = GrantItemOutput,
			reads = { "Catalog.Items" },
			writes = { "Player.Inventory" },
			creates = { "Player.Inventory.Items" },
			destroys = { "Player.Inventory.Items" },
			forbids = { "Workspace.Map" },
			preconditions = { "ProfileLoaded" },
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
				rateLimit = {
					maxRequests = 4,
					windowSeconds = 1,
				},
			},
			policy = {
				actorRequired = true,
			},
			tags = { "inventory" },
		})

	local description = grantContract:describe()
	check("system describes actions", description.actions.GrantItem.reads[1] == "Catalog.Items")
	check("action remote is registered", grantContract:actionForRemote("GrantItem") == "GrantItem")
	check("action remote options include rate limit", grantContract:remoteOptions("GrantItem").rateLimit.maxRequests == 4)
	check("action input validates", grantContract:validateActionInput("GrantItem", { ItemId = "Rifle" }).ok == true)

	local diagnostics = Contracts.diagnostics()
	local result = grantContract:runAction("GrantItem", {
		actor = "PlayerA",
		payload = {
			ItemId = "Rifle",
		},
		states = {
			Inventory = "Ready",
		},
		context = {
			profileLoaded = true,
			inventory = inventory,
		},
		diagnostics = diagnostics,
	}, function(scope)
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

	check("action runner succeeds", result.ok == true and result.value.itemId == "Rifle")
	check("action runner records effects", #result.effects == 2 and result.effects[1].kind == "read")
	check("action runner reduces lifecycle", result.lifecycle.states.Inventory == "Ready" and #result.lifecycle.transitions == 1)
	check("action runner avoids diagnostics on success", diagnostics:count() == 0)

	local invalidInputDiagnostics = Contracts.diagnostics()
	local handlerRan = false
	local invalidInput = grantContract:runAction("GrantItem", {
		actor = "PlayerA",
		payload = {
			ItemId = "../Rifle",
		},
		states = {
			Inventory = "Ready",
		},
		context = {
			profileLoaded = true,
			inventory = inventory,
		},
		diagnostics = invalidInputDiagnostics,
	}, function()
		handlerRan = true
	end)
	check("action runner rejects invalid input", invalidInput.ok == false and handlerRan == false)
	check("action runner records invalid input", invalidInputDiagnostics:last().name == "ActionInputInvalid")

	local preconditionDiagnostics = Contracts.diagnostics()
	local failedPrecondition = grantContract:runAction("GrantItem", {
		actor = "PlayerA",
		payload = {
			ItemId = "Sword",
		},
		states = {
			Inventory = "Ready",
		},
		context = {
			profileLoaded = false,
			inventory = inventory,
		},
		diagnostics = preconditionDiagnostics,
	}, function()
		return {
			granted = true,
			itemId = "Sword",
		}
	end)
	check("action runner rejects failed precondition", failedPrecondition.ok == false)
	check("action runner records named precondition", preconditionDiagnostics:last().name == "ProfileLoaded")

	local writeDiagnostics = Contracts.diagnostics()
	local badWrite = grantContract:runAction("GrantItem", {
		actor = "PlayerA",
		payload = {
			ItemId = "Shield",
		},
		states = {
			Inventory = "Ready",
		},
		context = {
			profileLoaded = true,
			inventory = inventory,
		},
		diagnostics = writeDiagnostics,
	}, function(scope)
		return scope:write("Player.Profile", function()
			return {
				granted = true,
				itemId = "Shield",
			}
		end)
	end)
	check("action scope rejects undeclared write", badWrite.ok == false and badWrite.name == "WriteNotAllowed")
	check("action scope records undeclared write", writeDiagnostics:last().name == "WriteNotAllowed")

	local forbiddenDiagnostics = Contracts.diagnostics()
	local forbiddenTouch = grantContract:runAction("GrantItem", {
		actor = "PlayerA",
		payload = {
			ItemId = "Shield",
		},
		states = {
			Inventory = "Ready",
		},
		context = {
			profileLoaded = true,
			inventory = inventory,
		},
		diagnostics = forbiddenDiagnostics,
	}, function(scope)
		return scope:touch("Workspace.Map.Tile", function()
			return {
				granted = true,
				itemId = "Shield",
			}
		end)
	end)
	check("action scope rejects forbidden touch", forbiddenTouch.ok == false and forbiddenTouch.name == "ForbiddenTouch")
	check("action scope records forbidden touch", forbiddenDiagnostics:last().name == "ForbiddenTouch")

	local outputDiagnostics = Contracts.diagnostics()
	local invalidOutput = grantContract:runAction("GrantItem", {
		actor = "PlayerA",
		payload = {
			ItemId = "Bow",
		},
		states = {
			Inventory = "Ready",
		},
		context = {
			profileLoaded = true,
			inventory = inventory,
		},
		diagnostics = outputDiagnostics,
	}, function()
		return {
			granted = true,
			item = "Bow",
		}
	end)
	check("action runner rejects invalid output", invalidOutput.ok == false)
	check("action runner records invalid output", outputDiagnostics:last().name == "ActionOutputInvalid")

	local lifecycleDiagnostics = Contracts.diagnostics()
	local invalidLifecycle = grantContract:runAction("GrantItem", {
		actor = "PlayerA",
		payload = {
			ItemId = "Potion",
		},
		states = {
			Inventory = "Locked",
		},
		context = {
			profileLoaded = true,
			inventory = inventory,
		},
		diagnostics = lifecycleDiagnostics,
	}, function()
		return {
			granted = true,
			itemId = "Potion",
		}
	end)
	check("action runner checks lifecycle state", invalidLifecycle.ok == false)
	check("action runner records lifecycle state failure", lifecycleDiagnostics:last().name == "ActionLifecycleStateInvalid")

	local actorDiagnostics = Contracts.diagnostics()
	local missingActor = grantContract:runAction("GrantItem", {
		payload = {
			ItemId = "Potion",
		},
		states = {
			Inventory = "Ready",
		},
		context = {
			profileLoaded = true,
			inventory = inventory,
		},
		diagnostics = actorDiagnostics,
	}, function()
		return {
			granted = true,
			itemId = "Potion",
		}
	end)
	check("action runner checks actor policy", missingActor.ok == false)
	check("action runner records actor policy failure", actorDiagnostics:last().name == "ActionActorRejected")

	local createAllowed = grantContract:checkActionEffect("GrantItem", {
		kind = "create",
		target = "Player.Inventory.Items.Rifle",
	})
	local destroyDenied = grantContract:checkActionEffect("GrantItem", {
		kind = "destroy",
		target = "Player.Inventory.Trash",
	})
	check("action effect allows declared create boundary", createAllowed.ok == true)
	check("action effect denies undeclared destroy boundary", destroyDenied.ok == false)

	test:section("PermissionCapabilities")

	local permissionContract = Contracts.system("ProfileService")
		:strictPermissions()
		:mayRead("Player.Profile")
		:mayWrite("Player.Inventory")
		:mustNeverTouch("Workspace.Map")
		:action("GrantItem", {
			reads = { "Player.Profile.Public" },
			writes = { "Player.Inventory.Items" },
			creates = { "Player.Inventory.Items" },
			destroys = { "Player.Inventory.Items" },
			touches = { "Player.Inventory.Items" },
			forbids = { "Player.Inventory.Locked" },
		})

	local permissionDescription = permissionContract:describe()
	check("system describes strict permissions", permissionDescription.strictPermissions == true)

	local readAllowed = permissionContract:checkRead("Player.Profile.Level")
	local readDenied = permissionContract:checkRead("Player.Inventory")
	check("standalone read allows declared boundary", readAllowed.ok == true and readAllowed.matchedSystemBoundary == "Player.Profile")
	check("standalone read rejects undeclared boundary", readDenied.ok == false and readDenied.name == "ReadNotAllowed")

	local writeAllowed = permissionContract:checkWrite("Player.Inventory.Items.Rifle")
	local writeDeniedDiagnostics = Contracts.diagnostics()
	local writeDenied = permissionContract:checkWrite("Player.Profile.Level", writeDeniedDiagnostics, {
		requestId = "write-denied",
	})
	check("standalone write allows declared boundary", writeAllowed.ok == true and writeAllowed.kind == "write")
	check(
		"standalone write rejects undeclared boundary",
		writeDenied.ok == false
			and writeDeniedDiagnostics:last().category == "permission"
			and writeDeniedDiagnostics:last().context.requestId == "write-denied"
	)

	local forbiddenReadDiagnostics = Contracts.diagnostics()
	local forbiddenRead = permissionContract:checkRead("Workspace.Map.Tile", forbiddenReadDiagnostics)
	check("forbidden boundary rejects reads", forbiddenRead.ok == false and forbiddenRead.name == "ForbiddenTouch" and forbiddenRead.strict == true)
	check("forbidden boundary records matched boundary", forbiddenReadDiagnostics:last().context.boundary == "Workspace.Map")

	local actionReadAllowed = permissionContract:checkActionRead("GrantItem", "Player.Profile.Public.DisplayName")
	local actionReadDenied = permissionContract:checkActionRead("GrantItem", "Player.Profile.Private.Email")
	check("action read allows narrowed boundary", actionReadAllowed.ok == true)
	check("action read rejects outside narrowed boundary", actionReadDenied.ok == false and actionReadDenied.name == "ReadNotAllowed")

	local actionWriteAllowed = permissionContract:checkActionWrite("GrantItem", "Player.Inventory.Items.Rifle")
	local actionWriteDenied = permissionContract:checkActionWrite("GrantItem", "Player.Inventory.Currency")
	check("action write allows narrowed boundary", actionWriteAllowed.ok == true)
	check("action write rejects outside narrowed boundary", actionWriteDenied.ok == false and actionWriteDenied.action == "GrantItem")

	local actionCreateAllowed = permissionContract:checkActionEffect("GrantItem", {
		kind = "create",
		target = "Player.Inventory.Items.Rifle",
	})
	local legacyActionCreateAllowed = permissionContract:checkEffect("GrantItem", {
		kind = "create",
		target = "Player.Inventory.Items.Rifle",
	})
	local actionTouchForbidden = permissionContract:checkActionEffect("GrantItem", {
		kind = "touch",
		target = "Player.Inventory.Locked.AdminOnly",
	})
	check("action effect allows declared create", actionCreateAllowed.ok == true)
	check("legacy action effect overload still works", legacyActionCreateAllowed.ok == true)
	check("action effect forbids action-specific boundary", actionTouchForbidden.ok == false and actionTouchForbidden.name == "ForbiddenTouch")

	local batch = permissionContract:checkEffects({
		{
			kind = "read",
			target = "Player.Profile.Level",
		},
		{
			kind = "write",
			target = "Player.Profile.Level",
		},
	})
	check("batch effects return all results", batch.ok == false and #batch.results == 2 and #batch.failures == 1)

	local actionBatch = permissionContract:checkActionEffects("GrantItem", {
		{
			kind = "read",
			target = "Player.Profile.Public.DisplayName",
		},
		{
			kind = "destroy",
			target = "Player.Inventory.Currency",
		},
	})
	check("action batch effects apply action boundaries", actionBatch.ok == false and actionBatch.failures[1].name == "DestroyNotAllowed")

	local permissiveContract = Contracts.system("PermissiveService")
	local permissiveRead = permissiveContract:checkRead("Anywhere.Path")
	local strictDenied = Contracts.system("StrictService")
		:strictPermissions()
		:checkRead("Anywhere.Path")
	check("non-strict empty permissions preserve compatibility", permissiveRead.ok == true)
	check("strict empty permissions deny by default", strictDenied.ok == false and strictDenied.name == "ReadNotAllowed")

	test:section("ActionBoundRemotes")

	local remoteContract = Contracts.system("RemoteInventory")
		:mayWrite("Player.Inventory")
		:postcondition("RemoteGrantReturned", function(context)
			return context.result ~= nil and context.result.granted == true and context.source == "test"
		end)
		:action("RemoteGrant", {
			input = GrantItemInput,
			output = GrantItemOutput,
			writes = { "Player.Inventory" },
			postconditions = { "RemoteGrantReturned" },
			remote = {
				name = "GrantRemote",
				direction = "server",
			},
		})

	local connectedHandler = nil
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

	local remoteDiagnostics = Contracts.diagnostics()
	RemoteGuard.connect(remoteContract, "GrantRemote", fakeRemote, function(player, payload, scope)
		return scope:write("Player.Inventory", function()
			return {
				granted = player == "PlayerA",
				itemId = payload.ItemId,
			}
		end)
	end, {
		diagnostics = remoteDiagnostics,
		context = {
			source = "test",
		},
	})

	local remoteResult = connectedHandler("PlayerA", {
		ItemId = "Rifle",
	})
	check("remote guard runs action-bound remote", remoteResult ~= nil and remoteResult.itemId == "Rifle")

	connectedHandler("PlayerA", {
		ItemId = "../Rifle",
	})
	check("remote guard records action input failure", remoteDiagnostics:last().name == "ActionInputInvalid")
end
