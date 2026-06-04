local Contracts = require("../src/Contracts")

local SpawnLifecycle = Contracts.lifecycle("SpawnLoadout")
	:transition("Menu", "SpawnRequested", "Spawning")
	:transition("Spawning", "Spawned", "Alive")
	:transition("Spawning", "SpawnFailed", "Menu")
	:transition("Alive", "Died", "Dead")
	:transition("Dead", "Respawn", "SpawnRequested")
	:transition("Dead", "MenuOpen", "Menu")

local function isAliveHumanoid(humanoid)
	return humanoid ~= nil and type(humanoid.Health) == "number" and humanoid.Health > 0
end

local function countNamedTool(container, toolName)
	if not container then
		return 0
	end

	if container.GetChildren then
		local count = 0
		for _, child in ipairs(container:GetChildren()) do
			if child.Name == toolName and child.IsA and child:IsA("Tool") then
				count += 1
			end
		end
		return count
	end

	local children = container.Children or {}
	local count = 0
	for _, child in pairs(children) do
		if child.Name == toolName and (child.ClassName == "Tool" or child.IsTool == true) then
			count += 1
		end
	end
	return count
end

local function countPlayerTools(player, toolName)
	return countNamedTool(player and player.Backpack, toolName) + countNamedTool(player and player.Character, toolName)
end

local SpawnRequestSchema = Contracts.object({
	Mode = Contracts.optional(Contracts.oneOf({ "solo", "team" })),
	SpawnPointId = Contracts.optional(Contracts.stringId()),
	NewSession = Contracts.optional(Contracts.boolean()),
}, {
	allowExtra = false,
})

local Contract = Contracts.system("SpawnLoadoutService")
	:ownsTag("StarterTool")
	:ownsFolder("Workspace.SpawnEffects")
	:mayRead("Workspace.SpawnPoints")
	:mayRead("Player.Character")
	:mayRead("Player.Backpack")
	:mayWrite("Player.RespawnLocation")
	:mayWrite("Player.Backpack.StarterTool")
	:mustNeverTouch("Workspace.Map")
	:lifecycle("Spawn", SpawnLifecycle)
	:remote("SpawnRequest", SpawnRequestSchema, {
		rateLimit = {
			maxRequests = 4,
			windowSeconds = 2,
		},
	})
	:postcondition("CharacterAliveAfterSpawn", function(context)
		return context.character ~= nil and isAliveHumanoid(context.humanoid)
	end)
	:postcondition("OneStarterToolAfterSpawn", function(context)
		local toolName = context.toolName or "StarterTool"
		return countPlayerTools(context.player, toolName) == 1
	end)

return {
	Contract = Contract,
	SpawnLifecycle = SpawnLifecycle,
	countPlayerTools = countPlayerTools,
}
