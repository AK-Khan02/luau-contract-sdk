local Contracts = require("../src/Contracts")

local EquipItemSchema = Contracts.object({
	ItemId = Contracts.stringId(),
	Slot = Contracts.integer(1, 10),
}, {
	allowExtra = false,
})

return Contracts.system("InventoryService")
	:ownsTag("InventoryItem")
	:mayRead("Player.Backpack")
	:mayWrite("Player.Backpack")
	:strictPermissions()
	:precondition("PlayerCanEquipItem", function(context)
		return context.player ~= nil
	end)
	:postcondition("EquippedItemExists", function(context)
		return context.findEquippedItem ~= nil and context.findEquippedItem(context.player, context.payload.ItemId) ~= nil
	end)
	:action("EquipItem", {
		input = EquipItemSchema,
		output = Contracts.object({
			equipped = Contracts.boolean(),
			itemId = Contracts.stringId(),
		}, {
			allowExtra = false,
		}),
		reads = { "Player.Backpack" },
		writes = { "Player.Backpack" },
		preconditions = { "PlayerCanEquipItem" },
		postconditions = { "EquippedItemExists" },
		remote = {
			name = "EquipItem",
			direction = "server",
		},
		policy = {
			actorRequired = true,
		},
		tags = { "inventory" },
	})
