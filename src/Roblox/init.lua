local function load(primaryPath, fallbackPath)
	local ok, module = pcall(require, primaryPath)
	if ok then
		return module
	end
	return require(fallbackPath)
end

return {
	GuardRemote = load("./GuardRemote", "./Roblox/GuardRemote"),
	Ownership = load("./Ownership", "./Roblox/Ownership"),
	OverlayState = load("./OverlayState", "./Roblox/OverlayState"),
	PlayerCancellation = load("./PlayerCancellation", "./Roblox/PlayerCancellation"),
	PlayersService = load("./PlayersService", "./Roblox/PlayersService"),
	PostconditionRunner = load("./PostconditionRunner", "./Roblox/PostconditionRunner"),
	RelayPublisher = load("./RelayPublisher", "./Roblox/RelayPublisher"),
	RemoteGuard = load("./RemoteGuard", "./Roblox/RemoteGuard"),
	StudioBridgePublisher = load("./StudioBridgePublisher", "./Roblox/StudioBridgePublisher"),
	TaskScheduler = load("./TaskScheduler", "./Roblox/TaskScheduler"),
}
