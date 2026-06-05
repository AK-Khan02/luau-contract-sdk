local Contracts = require("../src/Contracts")

local ActivateCheckpointSchema = Contracts.object({
	CheckpointId = Contracts.stringId(),
}, {
	allowExtra = false,
})

return Contracts.system("CheckpointService")
	:ownsTag("Checkpoint")
	:ownsTag("CheckpointSpawn")
	:mayRead("Workspace.Checkpoints")
	:mayWrite("Player.RespawnLocation")
	:strictPermissions()
	:postcondition("RespawnLocationMatchesCheckpoint", function(context)
		return context.player ~= nil and context.player.RespawnLocation == context.checkpointSpawn
	end)
	:action("ActivateCheckpoint", {
		input = ActivateCheckpointSchema,
		reads = { "Workspace.Checkpoints" },
		writes = { "Player.RespawnLocation" },
		postconditions = { "RespawnLocationMatchesCheckpoint" },
		remote = {
			name = "ActivateCheckpoint",
			direction = "server",
		},
	})
