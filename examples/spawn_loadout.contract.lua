--!strict

local Contracts = require("../src/Contracts")

local SpawnLifecycle = Contracts.lifecycle("SpawnLoadout")
	:transition("Menu", "SpawnRequested", "Spawning")
	:transition("Spawning", "Spawned", "Alive")
	:transition("Spawning", "SpawnFailed", "Menu")
	:transition("Alive", "Died", "Dead")
	:transition("Dead", "Respawn", "SpawnRequested")
	:transition("Dead", "MenuOpen", "Menu")

local function isAliveHumanoid(humanoid: any): boolean
	return humanoid ~= nil and type(humanoid.Health) == "number" and humanoid.Health > 0
end

local function countNamedTool(container: any, toolName: string): number
	if not container then
		return 0
	end

	if type(container.GetChildren) == "function" then
		local count = 0
		local getChildren = container.GetChildren :: (any) -> { any }
		for _, rawChild in ipairs(getChildren(container)) do
			local child: any = rawChild
			local isA = child.IsA
			if
				child.Name == toolName
				and type(isA) == "function"
				and (isA :: (any, string) -> boolean)(child, "Tool")
			then
				count += 1
			end
		end
		return count
	end

	local children = container.Children or {}
	local count = 0
	for _, rawChild in pairs(children) do
		local child: any = rawChild
		if child.Name == toolName and (child.ClassName == "Tool" or child.IsTool == true) then
			count += 1
		end
	end
	return count
end

local function countPlayerTools(player: any, toolName: string): number
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
	:strictPermissions()
	:lifecycle("Spawn", SpawnLifecycle)
	:postcondition("CharacterAliveAfterSpawn", function(context)
		return context.character ~= nil and isAliveHumanoid(context.humanoid)
	end)
	:postcondition("OneStarterToolAfterSpawn", function(context)
		local toolName = context.toolName or "StarterTool"
		return countPlayerTools(context.player, toolName) == 1
	end)
	:action("SpawnPlayer", {
		input = SpawnRequestSchema,
		output = Contracts.object({
			spawned = Contracts.boolean(),
			spawnPointId = Contracts.optional(Contracts.stringId()),
		}, {
			allowExtra = false,
		}),
		reads = {
			"Workspace.SpawnPoints",
			"Player.Character",
			"Player.Backpack",
		},
		writes = {
			"Player.RespawnLocation",
			"Player.Backpack.StarterTool",
		},
		postconditions = {
			"CharacterAliveAfterSpawn",
			"OneStarterToolAfterSpawn",
		},
		lifecycle = {
			requires = {
				Spawn = "Menu",
			},
			emits = {
				Spawn = "SpawnRequested",
			},
		},
		remote = {
			name = "SpawnRequest",
			direction = "server",
			rateLimit = {
				maxRequests = 4,
				windowSeconds = 2,
			},
		},
		policy = {
			actorRequired = true,
		},
		tags = { "spawn", "loadout" },
	})

return {
	Contract = Contract,
	SpawnLifecycle = SpawnLifecycle,
	countPlayerTools = countPlayerTools,
}
