local Contracts = require("../src/Contracts")

return Contracts.system("CheckpointService")
	:ownsTag("Checkpoint")
	:ownsTag("CheckpointSpawn")
	:mayRead("Workspace.Checkpoints")
	:mayWrite("Player.RespawnLocation")
	:remote("ActivateCheckpoint", Contracts.object({
		CheckpointId = Contracts.stringId(),
	}, {
		allowExtra = false,
	}))
	:postcondition("RespawnLocationMatchesCheckpoint", function(context)
		return context.player ~= nil and context.player.RespawnLocation == context.checkpointSpawn
	end)
