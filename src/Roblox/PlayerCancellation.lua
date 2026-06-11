local PlayerCancellation = {}

local function disconnect(connection)
	if connection and type(connection.Disconnect) == "function" then
		connection:Disconnect()
	end
end

function PlayerCancellation.cancelOnLeave(runtime, playersService)
	if runtime == nil or type(runtime.cancelActor) ~= "function" then
		error("PlayerCancellation.cancelOnLeave expects a runtime with cancelActor", 2)
	end

	local removing = playersService and playersService.PlayerRemoving
	if removing == nil or type(removing.Connect) ~= "function" then
		error("PlayerCancellation.cancelOnLeave expects a Players service with PlayerRemoving", 2)
	end

	local connection = removing:Connect(function(player) -- contracts-scan: ignore raw-remote-handler
		runtime:cancelActor(player, "player-left")
	end)

	local handle = {}

	function handle.destroy()
		if connection ~= nil then
			disconnect(connection)
			connection = nil
		end
	end

	return handle
end

return PlayerCancellation
