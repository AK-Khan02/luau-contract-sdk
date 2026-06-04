--!nocheck
--!nolint UnknownGlobal

local Contracts = require("../src/Contracts")
local RemoteGuard = Contracts.Roblox.RemoteGuard
local Ownership = Contracts.Roblox.Ownership

RemoteGuard.connect(Contract, "DeployRequest", Remote, function(player, payload)
	return payload
end)

local token = spawnToken
task.delay(1, function()
	if token ~= spawnToken then
		return
	end
	state.Ready = true
end)

Ownership.destroyOwned("CombatService", tool)

local effectsFolder = Workspace:FindFirstChild("CombatEffects")
if effectsFolder then
	effectsFolder:ClearAllChildren()
end
