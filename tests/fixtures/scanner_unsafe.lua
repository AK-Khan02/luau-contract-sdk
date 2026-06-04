--!nocheck
--!nolint UnknownGlobal

local Remote = {}
local Workspace = {}

Remote.OnServerEvent:Connect(function(player, payload)
	print(payload.Action)
end)

Workspace:ClearAllChildren()

local child = Workspace.CurrentArena
child:Destroy()

task.delay(1, function()
	child.Enabled = false
end)

Remote:FireServer({
	Action = "Deploy",
})
