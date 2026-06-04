local Contracts = require("../src/Contracts")

return Contracts.system("InventoryService")
	:ownsTag("InventoryItem")
	:mayRead("Player.Backpack")
	:mayWrite("Player.Backpack")
	:remote("EquipItem", Contracts.object({
		ItemId = Contracts.stringId(),
		Slot = Contracts.integer(1, 10),
	}, {
		allowExtra = false,
	}))
	:postcondition("EquippedItemExists", function(context)
		return context.findEquippedItem ~= nil and context.findEquippedItem(context.player, context.payload.ItemId) ~= nil
	end)
