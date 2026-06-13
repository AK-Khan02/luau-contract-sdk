--!strict

local PlayerCancellation = {}

local function disconnect(connection: any)
	if connection and type(connection.Disconnect) == "function" then
		local disconnectFn = connection.Disconnect :: (any) -> ()
		disconnectFn(connection)
	end
end

function PlayerCancellation.cancelOnLeave(runtime: any, playersService: any): any
	if runtime == nil or type(runtime.cancelActor) ~= "function" then
		error("PlayerCancellation.cancelOnLeave expects a runtime with cancelActor", 2)
	end

	local removing = playersService and playersService.PlayerRemoving
	if removing == nil or type(removing.Connect) ~= "function" then
		error("PlayerCancellation.cancelOnLeave expects a Players service with PlayerRemoving", 2)
	end

	local cancelActor = runtime.cancelActor :: (any, any, any?) -> any
	local connect = removing.Connect :: (any, (any) -> ()) -> any
	local connection = connect(removing, function(player: any) -- contracts-scan: ignore raw-remote-handler
		cancelActor(runtime, player, "player-left")
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
