--!nocheck

local Contracts = require("../../src/Contracts")
local Ownership = require("../../src/Roblox/Ownership")
local PostconditionRunner = require("../../src/Roblox/PostconditionRunner")
local RemoteGuard = require("../../src/Roblox/RemoteGuard")
local RobloxAdapters = require("../../src/Roblox")
local CheckpointContract = require("../../examples/checkpoint.contract")
local InventoryContract = require("../../examples/inventory.contract")
local SpawnLoadoutExample = require("../../examples/spawn_loadout.contract")

return function(test)
	local function check(name, condition)
		test:check(name, condition)
	end

	local weaponContract = Contracts.system("CombatService")
		:ownsTag("GeneratedWeaponTool")
		:ownsFolder("Workspace.CombatEffects")
		:mayRead("Player.Character")
		:mayWrite("Player.Backpack")
		:mustNeverTouch("Workspace.CurrentArena")
		:remote("WeaponAction", Contracts.object({
			Action = Contracts.oneOf({ "Fire", "Reload" }),
			WeaponId = Contracts.stringId(),
		}, {
			allowExtra = false,
		}))
		:postcondition("PlayerHasWeapon", function(context)
			return context.weaponCount == 1
		end)

	test:section("RemoteGuard")

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

	local guardDiagnostics = Contracts.diagnostics()
	local handledPayload = nil
	RemoteGuard.connect(weaponContract, "WeaponAction", fakeRemote, function(player, payload)
		handledPayload = payload
	end, {
		diagnostics = guardDiagnostics,
	})

	connectedHandler("PlayerA", { Action = "Fire", WeaponId = "Rifle" })
	check("remote guard forwards valid payload", handledPayload ~= nil and handledPayload.Action == "Fire")

	connectedHandler("PlayerA", { Action = "Hack", WeaponId = "Rifle" })
	check("remote guard records invalid payload", guardDiagnostics:last().name == "RemotePayloadInvalid")

	test:section("Roblox adapters")

	check("adapter init exports remote guard", RobloxAdapters.RemoteGuard == RemoteGuard)
	check("adapter init exports overlay state", RobloxAdapters.OverlayState ~= nil)

	local fakeInstance = {
		_attributes = {},
		destroyed = false,
		SetAttribute = function(self, key, value)
			self._attributes[key] = value
		end,
		GetAttribute = function(self, key)
			return self._attributes[key]
		end,
		GetFullName = function()
			return "Workspace.CombatEffects.Spark"
		end,
		Destroy = function(self)
			self.destroyed = true
		end,
	}

	Ownership.claim("CombatService", fakeInstance)
	check("ownership claim writes owner attribute", Ownership.ownerOf(fakeInstance) == "CombatService")
	check("ownership recognizes owner", Ownership.isOwnedBy("CombatService", fakeInstance) == true)

	local ownershipDiagnostics = Contracts.diagnostics()
	local wrongOwner = Ownership.assertOwned("MapService", fakeInstance, ownershipDiagnostics)
	check("ownership rejects wrong owner", wrongOwner == false)
	check("ownership records wrong owner", ownershipDiagnostics:last().name == "UnownedObjectTouch")
	check("ownership destroys owned instance", Ownership.destroyOwned("CombatService", fakeInstance) == true and fakeInstance.destroyed == true)

	local runnerDiagnostics = Contracts.diagnostics()
	local runnerResult = PostconditionRunner.run(weaponContract, "give weapon", { weaponCount = 1 }, runnerDiagnostics, function()
		return "done"
	end)
	check("postcondition runner returns action value", runnerResult.ok == true and runnerResult.value == "done")

	local failedRunnerResult = PostconditionRunner.run(
		weaponContract,
		"give weapon",
		{ weaponCount = 0 },
		runnerDiagnostics,
		function()
			return "done"
		end
	)
	check("postcondition runner reports failed postcondition", failedRunnerResult.ok == false)

	local overlayDiagnostics = Contracts.diagnostics()
	local overlayFeed = Contracts.OverlayFeed.new(overlayDiagnostics, {
		maxRows = 2,
	})
	overlayDiagnostics:record({ level = "warn", system = "MapService", name = "BroadCleanup", message = "broad cleanup" })
	overlayDiagnostics:record({ level = "error", system = "CombatService", name = "MissingWeapon", message = "missing weapon" })
	overlayDiagnostics:record({ level = "info", system = "SpawnService", name = "SpawnStarted", message = "spawn started" })
	check("overlay feed keeps max rows", #overlayFeed:rows() == 2)
	check("overlay feed exposes latest row", overlayFeed:latest().name == "SpawnStarted")
	check("overlay feed formats text", string.find(overlayFeed:text(), "MissingWeapon", 1, true) ~= nil)
	overlayFeed:destroy()

	local overlayStateDiagnostics = Contracts.diagnostics()
	local overlayState = RobloxAdapters.OverlayState.bind(overlayStateDiagnostics, {
		maxRows = 1,
	})
	overlayStateDiagnostics:record({ name = "OverlayHook", message = "hooked" })
	check("overlay state exposes rows", #overlayState.rows() == 1 and overlayState.latest().name == "OverlayHook")
	check("overlay state exposes text", string.find(overlayState.text(), "OverlayHook", 1, true) ~= nil)
	overlayState.destroy()

	test:section("Spawn/loadout example")

	local exampleContract = SpawnLoadoutExample.Contract
	local spawnValidation = exampleContract:validateRemote("SpawnRequest", {
		Mode = "team",
		SpawnPointId = "Spawn_A",
		NewSession = true,
	})
	check("example accepts valid spawn request", spawnValidation.ok == true)

	local unsafeSpawnValidation = exampleContract:validateRemote("SpawnRequest", {
		Mode = "solo",
		SpawnPointId = "../../Secret",
	})
	check("example rejects unsafe spawn request", unsafeSpawnValidation.ok == false)

	local fakePlayer = {
		Backpack = {
			Children = {},
		},
		Character = {
			Children = {
				{
					Name = "StarterTool",
					ClassName = "Tool",
				},
			},
		},
	}

	local exampleDiagnostics = Contracts.diagnostics()
	local exampleOk = exampleContract:checkPostconditions({
		player = fakePlayer,
		character = fakePlayer.Character,
		humanoid = {
			Health = 100,
		},
	}, exampleDiagnostics)

	check("example postconditions pass for equipped live character", exampleOk.ok == true)

	local exampleBad = exampleContract:checkPostconditions({
		player = {
			Backpack = { Children = {} },
			Character = { Children = {} },
		},
		character = {},
		humanoid = {
			Health = 100,
		},
	}, exampleDiagnostics)

	check("example postconditions fail for missing tool", exampleBad.ok == false)
	check("example records named missing tool invariant", exampleDiagnostics:last().name == "OneStarterToolAfterSpawn")

	test:section("Generic examples")

	check(
		"checkpoint example validates remote",
		CheckpointContract:validateRemote("ActivateCheckpoint", { CheckpointId = "Checkpoint_1" }).ok == true
	)
	check(
		"checkpoint example rejects extra remote field",
		CheckpointContract:validateRemote("ActivateCheckpoint", { CheckpointId = "Checkpoint_1", Admin = true }).ok == false
	)

	local fakeCheckpointPlayer = {
		RespawnLocation = "SpawnA",
	}
	local checkpointOk = CheckpointContract:checkPostconditions({
		player = fakeCheckpointPlayer,
		checkpointSpawn = "SpawnA",
	})
	check("checkpoint example postcondition passes", checkpointOk.ok == true)

	local equippedItems = {
		Rifle = true,
	}
	local inventoryOk = InventoryContract:checkPostconditions({
		player = "PlayerA",
		payload = {
			ItemId = "Rifle",
		},
		findEquippedItem = function(player, itemId)
			if equippedItems[itemId] then
				return itemId
			end
			return nil
		end,
	})
	check("inventory example postcondition passes", inventoryOk.ok == true)
end
